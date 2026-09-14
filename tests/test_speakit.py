"""Tests for the parts of SpeakIt that need no microphone.

Most of this project is Win32 behaviour and live audio, which is awkward to
test in CI. These cover the pure logic underneath: audio maths, the segment
merging, the cloud request shapes, config merging and the capped log stream.

Run them:

    .venv\\Scripts\\python.exe -m unittest discover -s tests -v

They use only the standard library plus numpy, so CI can run them on a machine
with no sound card.
"""

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import numpy as np  # noqa: E402

from speakit import config as config_module          # noqa: E402
from speakit.transcribe import (                     # noqa: E402
    CloudBackend, _default_keywords, _default_prompt, _join_segments,
    _merge_spans, pcm_to_float, pcm_to_wav,
)

RATE = 16000


def tone(seconds, freq=200.0, amplitude=0.4, rate=RATE):
    """A voiced-sounding buffer. Not speech, but not silence either."""
    t = np.arange(int(seconds * rate)) / rate
    wave = np.sin(2 * np.pi * freq * t) * amplitude
    return (wave * 32767).astype(np.int16).tobytes()


def silence(seconds, rate=RATE):
    return np.zeros(int(seconds * rate), dtype=np.int16).tobytes()


class AudioMaths(unittest.TestCase):
    def test_pcm_to_float_round_trips_scale(self):
        pcm = np.array([0, 16384, -16384], dtype=np.int16).tobytes()
        out = pcm_to_float(pcm)
        self.assertEqual(out.dtype, np.float32)
        self.assertAlmostEqual(out[0], 0.0, places=4)
        self.assertAlmostEqual(out[1], 0.5, places=3)
        self.assertAlmostEqual(out[2], -0.5, places=3)

    def test_pcm_to_float_handles_empty(self):
        self.assertEqual(len(pcm_to_float(b"")), 0)

    def test_pcm_to_wav_has_a_riff_header(self):
        wav = pcm_to_wav(tone(0.1), RATE)
        self.assertTrue(wav.startswith(b"RIFF"))
        self.assertIn(b"WAVE", wav[:16])
        # 16-bit mono at the rate we asked for.
        self.assertEqual(int.from_bytes(wav[24:28], "little"), RATE)
        self.assertEqual(int.from_bytes(wav[34:36], "little"), 16)


class MergeSpans(unittest.TestCase):
    """Whisper pads every piece to 30s, so segment count is what costs time."""

    def test_caps_the_number_of_segments(self):
        spans = [(i * RATE, i * RATE + RATE) for i in range(10)]
        merged = _merge_spans(spans, RATE, max_segments=3, min_keep=0.0)
        self.assertLessEqual(len(merged), 3)

    def test_absorbs_segments_that_are_too_short(self):
        spans = [(0, RATE * 2), (RATE * 3, RATE * 3 + RATE // 10)]
        merged = _merge_spans(spans, RATE, max_segments=5, min_keep=1.2)
        self.assertEqual(len(merged), 1, "a 0.1s span should not survive")

    def test_keeps_span_order_and_bounds(self):
        spans = [(0, RATE), (RATE * 2, RATE * 3), (RATE * 4, RATE * 5)]
        merged = _merge_spans(spans, RATE, max_segments=2, min_keep=0.0)
        self.assertEqual(merged[0][0], 0)
        self.assertEqual(merged[-1][1], RATE * 5)
        for lo, hi in merged:
            self.assertLess(lo, hi)

    def test_empty_input(self):
        self.assertEqual(_merge_spans([], RATE, 3, 1.2), [])


class JoinSegments(unittest.TestCase):
    def test_drops_trailing_ellipsis_except_on_the_last_piece(self):
        joined = _join_segments(["I said this...", "and then that..."])
        self.assertEqual(joined, "I said this and then that...")

    def test_skips_empty_pieces(self):
        self.assertEqual(_join_segments(["one", "  ", "two"]), "one two")

    def test_no_doubled_spaces(self):
        self.assertNotIn("  ", _join_segments([" one ", " two "]))


class CloudRequestShapes(unittest.TestCase):
    """The fallback ladder must degrade, never drop the languages list.

    Sending `languages` is what buys mid-sentence switching, so a bug that
    silently dropped it would look like a quality regression rather than a
    broken request.
    """

    def setUp(self):
        self.cfg = config_module.load()
        self.cfg["transcription"]["cloud"]["languages"] = ["en", "ru", "de"]
        self.cfg["transcription"]["cloud"]["keywords"] = ["Kubernetes"]
        self.backend = CloudBackend(self.cfg)

    def test_first_shape_sends_the_language_list(self):
        first = self.backend._field_variants("")[0]
        self.assertEqual(first.get("languages[]"), ["en", "ru", "de"])
        # Configured keywords are kept, with the glue words appended. See
        # GlueKeywords below for why they are there.
        self.assertIn("Kubernetes", first.get("keywords[]"))

    def test_ladder_degrades_to_a_singular_language(self):
        variants = self.backend._field_variants("")
        singular = [v for v in variants if "language" in v]
        self.assertTrue(singular, "no singular-language fallback in the ladder")
        self.assertEqual(singular[0]["language"], "en")

    def test_every_shape_names_the_model(self):
        for fields in self.backend._field_variants(""):
            self.assertIn("model", fields)

    def test_a_pinned_language_overrides_the_list(self):
        first = self.backend._field_variants("de")[0]
        self.assertEqual(first.get("languages[]"), ["de"])


class SteeringPrompt(unittest.TestCase):
    """Accented speech gets transliterated without this.

    A German phrase read in a Russian accent came back as Cyrillic gibberish
    on 6 attempts out of 6 with no prompt, and 0 out of 6 with one. The
    wording is deliberately short: a longer, more explicit version failed all
    6, so this is not a knob to elaborate on casually.
    """

    def test_names_every_configured_language(self):
        prompt = _default_prompt(["en", "ru", "de", "kk"])
        for name in ("English", "Russian", "German", "Kazakh"):
            self.assertIn(name, prompt)

    def test_reads_as_a_sentence(self):
        self.assertEqual(_default_prompt(["en", "ru", "de"]),
                         "The speaker mixes English, Russian and German.")

    def test_no_prompt_when_there_is_nothing_to_mix(self):
        self.assertEqual(_default_prompt(["en"]), "")
        self.assertEqual(_default_prompt([]), "")

    def test_unknown_codes_still_produce_something(self):
        self.assertIn("zz", _default_prompt(["en", "zz"]))

    def test_a_configured_prompt_wins(self):
        cfg = config_module.load()
        cfg["transcription"]["cloud"]["prompt"] = "my own wording"
        fields = CloudBackend(cfg)._field_variants("")[0]
        self.assertEqual(fields.get("prompt"), "my own wording")

    def test_generated_prompt_is_used_when_none_is_set(self):
        cfg = config_module.load()
        cfg["transcription"]["cloud"]["prompt"] = ""
        cfg["transcription"]["cloud"]["languages"] = ["en", "de"]
        fields = CloudBackend(cfg)._field_variants("")[0]
        self.assertEqual(fields.get("prompt"),
                         "The speaker mixes English and German.")


class GlueKeywords(unittest.TestCase):
    """Short German words vanish in connected speech without these.

    Nobody pronounces the final -r in "aber"; it reduces to a schwa, so the
    microphone hears roughly "aba". Straight after Cyrillic that either
    becomes "Абы" or disappears. Measured: "aber" survived 0 of 3 attempts
    without these keywords and 3 of 3 with them, while five clean clips in
    other languages were byte-identical either way.
    """

    def test_german_contributes_glue_words(self):
        words = _default_keywords(["en", "ru", "de", "kk"])
        self.assertIn("aber", words)
        self.assertIn("Aber", words)

    def test_nothing_for_languages_with_no_list(self):
        self.assertEqual(_default_keywords(["en", "ru"]), [])
        self.assertEqual(_default_keywords([]), [])

    def test_no_duplicates(self):
        words = _default_keywords(["de", "de"])
        self.assertEqual(len(words), len(set(words)))

    def test_configured_keywords_are_kept_alongside_the_glue(self):
        cfg = config_module.load()
        cfg["transcription"]["cloud"]["keywords"] = ["Kubernetes"]
        cfg["transcription"]["cloud"]["languages"] = ["en", "de"]
        sent = CloudBackend(cfg)._field_variants("")[0].get("keywords[]")
        self.assertIn("Kubernetes", sent)
        self.assertIn("aber", sent)

    def test_glue_is_absent_when_german_is_not_configured(self):
        cfg = config_module.load()
        cfg["transcription"]["cloud"]["keywords"] = []
        cfg["transcription"]["cloud"]["languages"] = ["en", "ru"]
        sent = CloudBackend(cfg)._field_variants("")[0].get("keywords[]")
        self.assertFalse(sent)


class ConfigMerge(unittest.TestCase):
    def test_user_values_win_but_defaults_survive(self):
        merged = config_module._deep_merge(
            config_module.DEFAULTS, {"model": {"final": "small"}}
        )
        self.assertEqual(merged["model"]["final"], "small")
        self.assertEqual(
            merged["model"]["realtime"], config_module.DEFAULTS["model"]["realtime"]
        )

    def test_merge_does_not_mutate_the_defaults(self):
        before = config_module.DEFAULTS["model"]["final"]
        config_module._deep_merge(config_module.DEFAULTS,
                                  {"model": {"final": "large-v3-turbo"}})
        self.assertEqual(config_module.DEFAULTS["model"]["final"], before)

    def test_defaults_that_were_chosen_by_measurement(self):
        # These were chosen by measurement. If you are
        # changing one, change it here too and say why in the pull request.
        rec = config_module.DEFAULTS["recording"]
        self.assertEqual(rec["vad_aggressiveness"], 1)
        self.assertEqual(rec["min_speech_run"], 12)
        self.assertTrue(rec["normalize_for_transcription"])
        self.assertIsNone(config_module.DEFAULTS["model"]["initial_prompt"])


class HardwareResolution(unittest.TestCase):
    def test_explicit_values_are_left_alone(self):
        from speakit.hardware import resolve_hardware
        self.assertEqual(resolve_hardware("cpu", "int8"), ("cpu", "int8"))

    def test_auto_compute_type_follows_the_device(self):
        from speakit.hardware import resolve_hardware
        self.assertEqual(resolve_hardware("cuda", "auto")[1], "float16")
        self.assertEqual(resolve_hardware("cpu", "auto")[1], "int8")

    def test_auto_device_resolves_to_something_usable(self):
        from speakit.hardware import resolve_hardware
        device, compute = resolve_hardware("auto", "auto")
        self.assertIn(device, ("cpu", "cuda"))
        self.assertIn(compute, ("int8", "float16"))


class CappedLogStream(unittest.TestCase):
    """A runaway dependency once wrote 8.7 GB here. It must not happen twice."""

    def _stream_class(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "speakit_run", ROOT / "run.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module._CappedStream

    def test_stops_writing_at_the_limit(self):
        capped = self._stream_class()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.log"
            stream = capped(path, "w", 1000)
            for i in range(500):
                stream.write("a traceback line {}\n".format(i))
            stream.flush()
            stream.close()
            self.assertLess(path.stat().st_size, 1500)
            self.assertIn("limit", path.read_text(encoding="utf-8"))

    def test_write_reports_the_full_length_even_when_dropping(self):
        capped = self._stream_class()
        with tempfile.TemporaryDirectory() as tmp:
            stream = capped(Path(tmp) / "out.log", "w", 10)
            stream.write("x" * 50)
            # print() checks the return value; lying about it breaks callers.
            self.assertEqual(stream.write("y" * 30), 30)
            stream.close()


class KeyFile(unittest.TestCase):
    """Renaming the project from VoiceType must not lose anyone's saved key."""

    def _backend(self, appdata):
        import copy
        import os
        from unittest import mock

        cfg = copy.deepcopy(config_module.DEFAULTS)
        variable = cfg["transcription"]["cloud"]["api_key_env"]
        env = {k: v for k, v in os.environ.items() if k != variable}
        env["APPDATA"] = appdata
        return CloudBackend(cfg), mock.patch.dict(os.environ, env, clear=True)

    def _write(self, folder, key):
        folder.mkdir()
        (folder / "openai.key").write_text(key + "\n", encoding="utf-8")

    def test_reads_the_current_location(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write(Path(tmp) / "SpeakIt", "test-key-new")
            backend, env = self._backend(tmp)
            with env:
                self.assertEqual(backend.api_key, "test-key-new")

    def test_falls_back_to_the_voicetype_location(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write(Path(tmp) / "VoiceType", "test-key-old")
            backend, env = self._backend(tmp)
            with env:
                self.assertEqual(backend.api_key, "test-key-old")

    def test_current_location_wins_when_both_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write(Path(tmp) / "SpeakIt", "test-key-new")
            self._write(Path(tmp) / "VoiceType", "test-key-old")
            backend, env = self._backend(tmp)
            with env:
                self.assertEqual(backend.api_key, "test-key-new")


from speakit import languages  # noqa: E402


class LanguageList(unittest.TestCase):
    """Adding and removing languages from the tray."""

    def _cfg(self, codes, pinned=""):
        import copy

        cfg = copy.deepcopy(config_module.DEFAULTS)
        cfg["transcription"]["cloud"]["languages"] = list(codes)
        cfg["model"]["language"] = pinned
        cfg["model"]["language_menu"] = languages.menu_for(codes)
        return cfg

    def test_adding_updates_both_lists(self):
        cfg = self._cfg(["en"])
        self.assertEqual(languages.toggle(cfg, "fr"), "added")
        self.assertEqual(cfg["transcription"]["cloud"]["languages"],
                         ["en", "fr"])
        self.assertEqual(cfg["model"]["language_menu"],
                         {"Auto-detect": "", "English": "en", "French": "fr"})

    def test_removing_a_pinned_language_unpins_it(self):
        cfg = self._cfg(["en", "de"], pinned="de")
        self.assertEqual(languages.toggle(cfg, "de"), "removed")
        self.assertEqual(cfg["transcription"]["cloud"]["languages"], ["en"])
        self.assertEqual(cfg["model"]["language"], "")
        self.assertNotIn("German", cfg["model"]["language_menu"])

    def test_the_last_language_stays(self):
        cfg = self._cfg(["en"])
        self.assertEqual(languages.toggle(cfg, "en"), "kept")
        self.assertEqual(cfg["transcription"]["cloud"]["languages"], ["en"])

    def test_the_list_is_edited_in_place(self):
        # The tray keeps a reference to this list to draw its checkmarks.
        cfg = self._cfg(["en"])
        held = cfg["transcription"]["cloud"]["languages"]
        languages.toggle(cfg, "kk")
        self.assertIs(held, cfg["transcription"]["cloud"]["languages"])
        self.assertEqual(held, ["en", "kk"])

    def test_reconcile_keeps_what_either_list_named(self):
        cfg = self._cfg(["en"], pinned="es")
        cfg["model"]["language_menu"] = {
            "Auto-detect": "", "English": "en", "French": "fr"}
        self.assertTrue(languages.reconcile(cfg))
        self.assertEqual(cfg["transcription"]["cloud"]["languages"],
                         ["en", "fr", "es"])
        self.assertFalse(languages.reconcile(cfg))

    def test_the_defaults_already_agree(self):
        import copy

        cfg = copy.deepcopy(config_module.DEFAULTS)
        self.assertFalse(languages.reconcile(cfg))

    def test_unknown_codes_are_shown_as_codes(self):
        self.assertEqual(languages.name("xx"), "xx")
        self.assertIn("xx", languages.catalog(["en", "xx"]))
        self.assertEqual(languages.catalog([])[0], "af")


class LanguageGroups(unittest.TestCase):
    """The letter submenus under Add or remove languages."""

    def setUp(self):
        self.codes = languages.catalog(["en", "xx"])
        self.groups = languages.groups(self.codes)

    def test_every_language_is_in_exactly_one_group(self):
        flat = [code for _, codes in self.groups for code in codes]
        self.assertEqual(sorted(flat), sorted(self.codes))

    def test_no_group_runs_off_the_screen(self):
        for label, codes in self.groups:
            self.assertLessEqual(len(codes), languages.GROUP_SIZE, label)

    def test_a_letter_never_spans_two_groups(self):
        seen = set()
        for _, codes in self.groups:
            letters = {languages.name(code)[:1].upper() for code in codes}
            self.assertFalse(letters & seen)
            seen |= letters

    def test_labels_name_the_first_and_last_letter(self):
        for label, codes in self.groups:
            self.assertEqual(label[0], languages.name(codes[0])[0].upper())
            self.assertEqual(label[-1], languages.name(codes[-1])[0].upper())

    def test_only_codes_openai_accepts(self):
        self.assertIn("tl", languages.NAMES)
        self.assertNotIn("yue", languages.NAMES)
        self.assertTrue(all(len(code) == 2 for code in languages.NAMES))


if __name__ == "__main__":
    unittest.main(verbosity=2)
