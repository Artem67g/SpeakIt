<div align="center">

# SpeakIt

**Dictation software makes you pick a language before you start talking.**

SpeakIt assumes you are going to switch, probably mid-sentence.

Hold Ctrl+Alt, talk, and the text lands in whatever window you were already
typing in. No console window, nothing in the taskbar, nothing in Alt+Tab. Just
a microphone in the tray.

Windows. Built on [RealtimeSTT](https://github.com/KoljaB/RealtimeSTT). MIT.

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Built on RealtimeSTT](https://img.shields.io/badge/built%20on-RealtimeSTT-8A2BE2)](https://github.com/KoljaB/RealtimeSTT)
[![Stars](https://img.shields.io/github/stars/Maslitsa/SpeakIt?style=social)](https://github.com/Maslitsa/SpeakIt/stargazers)

<img src="docs/img/overlay-hero.png" width="720" alt="The SpeakIt pill above the taskbar showing a live waveform and a sentence that starts in English and continues in Russian">

</div>

---

## Install

Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1 | iex
```

It downloads about 1 GB, installs into `%LOCALAPPDATA%\Programs\SpeakIt`,
starts SpeakIt with Windows and launches it. Then hold Ctrl+Alt and talk.

### With your OpenAI key (recommended)

OpenAI is much more accurate than the model on your computer, and it is the
only option that keeps up when you switch language in the middle of a
sentence. Create a key at
[platform.openai.com/api-keys](https://platform.openai.com/api-keys), put it
between the quotes, and paste the whole line into PowerShell instead:

```powershell
$env:OPENAI_API_KEY = "PASTE-YOUR-KEY-HERE"; irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1 | iex
```

Filled in, it looks like this:

<pre>$env:OPENAI_API_KEY = "<a href="docs/no-key-for-you.md">sk-proj-R4nd0m...x9Qz</a>"; irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1 | iex</pre>

The installer checks the key with OpenAI, saves it to
`%APPDATA%\SpeakIt\openai.key` where only your account can read it, and takes
it back out of your PowerShell history. To change the key later, run the same
line with the new one.

It is your own key on your own OpenAI account. Nothing is proxied. Cost is
about $0.006 per minute of audio, roughly $3.60 a month at 20 minutes of
dictation a day. Check [current pricing](https://openai.com/api/pricing/).

If you use the first command, the installer asks which one you want, and takes
the key there instead.

### Updating, and if it fails

Run the same command again to update. Your settings are kept.

If it fails, the window stays open with the reason, and the whole run is in
`%TEMP%\SpeakIt-install.log`. If your antivirus blocks the command, use the ZIP
and `INSTALL.bat` described below. If you hit a problem, please
[open an issue](https://github.com/Maslitsa/SpeakIt/issues) and attach that
log, so I can fix it.

<details>
<summary><b>Options, or a different install location</b></summary>

<br>

To pass arguments, load the script into a script block in PowerShell:

```powershell
$s = [scriptblock]::Create((irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1))
& $s -InstallDir 'D:\Apps\SpeakIt'
& $s -Backend local
& $s -NoAutostart
```

</details>

<details>
<summary><b>Without piping a script from the internet</b></summary>

<br>

Read [install.ps1](install.ps1) first, or skip the pipe:

```powershell
git clone https://github.com/Maslitsa/SpeakIt.git
cd SpeakIt
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

If you would rather not use a terminal at all, download the
[ZIP](https://github.com/Maslitsa/SpeakIt/archive/refs/heads/main.zip), unzip
it somewhere permanent and double-click `INSTALL.bat`.

</details>

## Set your languages

Click the microphone icon in the tray, then **Language > Add or remove
languages**. Your languages are at the top: untick one to remove it. Below them
is every other language Whisper knows, grouped by first letter. Open the group
and tick yours.

The ones you tick show up in the Language menu, where you can pin one for a
while if auto-detect keeps guessing wrong. The OpenAI model is told to expect
them, so tick only the languages you actually speak. The default is English,
Russian, German and Kazakh, because that is what I speak.

If you stay on the local model and switch language mid-sentence, also set
`"per_segment_language": true` in **Edit settings**. It ships off because it
costs punctuation accuracy and about 1.7x in speed, which is a bad trade for
anyone dictating in one language. It only helps when you pause at the switch.

## How you use it

| Gesture | What happens |
| --- | --- |
| Hold Ctrl+Alt for longer than 0.7s | Records while held. Release to transcribe and insert. |
| Tap Ctrl+Alt and release under 0.7s | Latches on for hands-free dictation. Tap again to finish, or stop talking and it ends after 2.5s of silence. |
| Any other key while recording | Cancels. Nothing is inserted. |
| Tray icon | Status, your languages, OpenAI or local, pause the hotkey, edit settings, quit. |

<div align="center">
<img src="docs/img/overlay-listening.png" width="620" alt="Listening state with a red dot, live waveform and grey preview text"><br>
<em>Listening. Preview text is grey because it comes from a small fast model and is only a guess.</em><br><br>
<img src="docs/img/overlay-done.png" width="620" alt="Done state with a green dot and the final transcript in white"><br>
<em>Done. White text is the final transcript, already pasted and on the clipboard.</em>
</div>

## Why it exists

Whisper picks one language per utterance. Anything you said in another language
comes back translated, or it disappears. And a lot of the other tools keep a
black console window open while they run. SpeakIt has none: it sits in the
tray, behind the little arrow next to the clock.

Here is Whisper `base` on a sentence that starts in English and ends in
Russian:

```
Spoken:  I already sent the invoice yesterday, but клиент до сих пор
         не ответил на моё письмо.

Got:     I've already sent me an voice yesterday, but today children
         mind your piece more
```

Bigger models make this worse. On the same clip, `small` and `large-v3-turbo`
both dropped the entire English half that `base` had kept, because more
capacity means a stronger single-language prior.

SpeakIt handles it two ways, switchable from the tray: locally, by splitting
the recording at pauses and detecting the language of each piece; or through
OpenAI, by sending a list of languages rather than one.

## Try it before you trust it

There is an 11 second clip in the repo that changes language three times with
no pause at the switches, English to German to Russian to Kazakh. Run it from
the SpeakIt folder:

```powershell
cd "$env:LOCALAPPDATA\Programs\SpeakIt"
.venv\Scripts\python.exe tools\try_demo.py --both
```

```
cloud   3.6s
        I already sent the invoice. Aber ich warte noch auf eine Antwort.
        Но клиент до сих пор не ответил. Сондықтан ертең қоңырау шаламын.

local   1.7s
        I already sent the invoice.
```

It takes a 16-bit wav of your own too, which is the harder test. Give the full
path, since you are in the SpeakIt folder:

```powershell
.venv\Scripts\python.exe tools\try_demo.py "$HOME\Desktop\my_recording.wav" --both
```

The clip is synthesised speech, which is cleaner than a real voice.
[demo/README.md](demo/README.md) says what that does and does not prove.

## Local or OpenAI

Both measured on the same machine, a Ryzen 7 7730U with no GPU, against the
same audio played through speakers into the microphone.

| | Local (default) | OpenAI |
| --- | --- | --- |
| Model | Whisper `base` on your CPU | `gpt-transcribe` |
| Wait after you stop | 1.5 to 1.9s, consistent | 1.1 to 2.6s typical, 7.7s seen |
| English | good | better |
| German | good | better |
| Russian | the weak one | much better |
| Mid-sentence switching | only across a pause | yes, with no pause |
| Cost | free | about $0.006/min |
| Privacy | nothing leaves the machine | audio is uploaded when you dictate |
| Offline | yes | no |

The cloud is not the faster option. Its median is close to local and its worst
case is much worse, because it depends on your connection. Switch to it for
Russian, German and mid-sentence switching, not for speed.

## Something wrong?

Double-click `CHECKUP.bat` in the SpeakIt folder, or run:

```powershell
cd "$env:LOCALAPPDATA\Programs\SpeakIt"
.venv\Scripts\python.exe tools\doctor.py
```

It checks the Python version, the dependencies, your settings, the microphone,
the API key, whether SpeakIt is running and whether it starts with Windows.
Anything it cannot fix gets a line telling you what to do.

[docs/troubleshooting.md](docs/troubleshooting.md) goes deeper.

## Uninstall

Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/uninstall.ps1 | iex
```

It removes every copy of SpeakIt on this PC, including old ones called
VoiceType, with their shortcuts, your saved OpenAI key and the downloaded
speech models. A folder that is a git clone is left where it is.

## Requirements

* Windows 10 or 11. The hotkey, the overlay and the paste path are all Win32.
* Nothing else. The installer brings its own Python.
* A microphone. If you are not sure yours is good enough, run
  `.venv\Scripts\python.exe tools\check_mic.py` in the SpeakIt folder while
  speaking and it will tell you.
* No GPU needed. A CUDA GPU makes local transcription much faster if you have
  one.

## Related projects

[FluidVoice](https://altic.dev/fluid) is the closest thing to this: open
source, local-first, and it runs Nemotron and Parakeet as well as Whisper. It
is macOS only for now, with Windows on a waitlist. If you are on a Mac, use it.

[whisperX](https://github.com/m-bain/whisperX) transcribes audio files with
word-level timestamps and diarization, and its alignment models are
language-specific. Windows voice typing (Win+H) is good and handles one
language at a time. [Wispr Flow](https://wisprflow.ai) is a polished commercial
app, closed source and cloud only.

I have not benchmarked the other Windows dictation tools on GitHub, so I am not
claiming to beat them. If one of them handles language switching properly I
would rather know.

## Credits

SpeakIt is built on [RealtimeSTT](https://github.com/KoljaB/RealtimeSTT) by
[Kolja Beigel](https://github.com/KoljaB). RealtimeSTT does the microphone
pipeline, the voice activity detection that ends a hands-free recording, and
the live preview transcript. Those are the parts that make dictation feel
immediate, and none of them are mine. If SpeakIt is useful to you, star
RealtimeSTT too.

Transcription is [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
running [OpenAI Whisper](https://github.com/openai/whisper), or the OpenAI API.

Full attribution in [NOTICE](NOTICE).

## License

MIT. See [LICENSE](LICENSE).
