<#
.SYNOPSIS
    Installs SpeakIt, updates it, or removes it.

.DESCRIPTION
    One command, from PowerShell, cmd or the Run dialog:

        powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1 | iex"

    You do not need Python. The script downloads uv, a single-file Python
    manager, and uv downloads the exact Python SpeakIt is tested on into the
    install folder. Whatever Python you already have is never used: none,
    3.13, the Microsoft Store one and conda all behave the same.

    Run it again to update. config.json and the speech models are kept.

    If it fails, the window stays open, the last lines say why, and the whole
    run is in %TEMP%\SpeakIt-install.log.

.PARAMETER InstallDir
    Where to install when downloading. Defaults to
    %LOCALAPPDATA%\Programs\SpeakIt. Ignored when this script is run from a
    copy of the project, which installs that copy.

.PARAMETER SetApiKey
    Prompts for an OpenAI API key and stores it outside the project, readable
    only by you. Only needed for the cloud backend.

.PARAMETER Uninstall
    Stops SpeakIt and removes its shortcuts. Leaves the folder and the key.

.PARAMETER NoStart
    Set everything up but do not launch the app.

.PARAMETER NoAutostart
    Do not start SpeakIt when you sign in.

.EXAMPLE
    # Arguments with the one-command install:
    $s = [scriptblock]::Create((irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1))
    & $s -InstallDir 'D:\Apps\SpeakIt'

.EXAMPLE
    # From a copy of the project:
    INSTALL.bat
    INSTALL.bat -SetApiKey
    UNINSTALL.bat
#>
param(
    [switch]$Uninstall,
    [switch]$SetApiKey,
    [switch]$NoStart,
    [switch]$NoAutostart,
    [string]$InstallDir
)

# Empty when piped into iex, which is how the one-command install runs.
$SelfPath = $PSCommandPath

# Everything happens inside this block. Piped into iex, a script runs in the
# caller's own session, so without it every preference and variable set here
# would leak into their PowerShell, and a plain `exit` would close the window
# they need to read the error in.
& {

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is several times slower while drawing its progress bar.
$ProgressPreference = 'SilentlyContinue'

$AppName   = 'SpeakIt'
$RepoUrl   = 'https://github.com/Maslitsa/SpeakIt'
# Lets a branch be tried before it reaches main.
$Ref       = if ($env:SPEAKIT_REF) { $env:SPEAKIT_REF } else { 'main' }

# uv is pinned, and checked against the SHA-256 published with that release,
# because the installer runs it.
$UvVersion = '0.12.13'
$UvSha256  = 'a86c9dc7bad9b03f388583b7187c05fe9951c2e0d392217e8fd43d97787f6ec2'

# RealtimeSTT declares python_requires >=3.11,<3.13. Always the x86_64 build:
# it also runs on ARM laptops through Windows 11's emulation, and PyAudio and
# ctranslate2 publish no ARM wheels.
$PythonRequest = 'cpython-3.12-windows-x86_64-none'

$MinFreeGB = 3
# Deepest file an install creates, measured below the folder: 149
# characters, in uv's cache. Windows refuses paths over 260 unless long paths
# are enabled, and a failure there surfaces as an unrelated build error.
$MaxRootLength = 90

$LegacyName = 'VoiceType'
$LogFile    = Join-Path $env:TEMP 'SpeakIt-install.log'

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-Log([string]$Text) {
    try { Add-Content -LiteralPath $LogFile -Value $Text -Encoding UTF8 } catch {}
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
    Write-Log "==> $Text"
}

function Write-Note([string]$Text) {
    Write-Host "    $Text"
    Write-Log "    $Text"
}

function Invoke-Native([string]$What, [string]$Exe, [string[]]$Arguments) {
    # Windows PowerShell turns every stderr line of a native program into an
    # error record, and with ErrorActionPreference at Stop the first one aborts
    # the script. uv and pip write ordinary progress to stderr.
    Write-Log "> $Exe $($Arguments -join ' ')"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Empty stdin. Nothing here should ever wait for an answer, and a
        # prompt nobody can see would hang the install instead of failing it.
        $null | & $Exe @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            Write-Host "    $line"
            Write-Log "    $line"
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        throw "$What failed (exit code $code). The lines above say why."
    }
}

$SavedEnv = @{}
function Set-ProcessEnv([string]$Name, [string]$Value) {
    if (-not $SavedEnv.ContainsKey($Name)) {
        $SavedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

if ($SelfPath) {
    $Root = Split-Path -Parent $SelfPath
} elseif ($InstallDir) {
    $Root = $InstallDir
} else {
    # Not Documents or Desktop: those are often synced by OneDrive, which would
    # try to upload a gigabyte of Python packages.
    $Root = Join-Path $env:LOCALAPPDATA "Programs\$AppName"
}
$Root = [IO.Path]::GetFullPath($Root)

$UvDir       = Join-Path $Root '.uv'
$VenvDir     = Join-Path $Root '.venv'
$VenvPy      = Join-Path $VenvDir 'Scripts\python.exe'
$VenvPyW     = Join-Path $VenvDir 'Scripts\pythonw.exe'
$EntryFile   = Join-Path $Root 'run.py'
$StartupDir  = [Environment]::GetFolderPath('Startup')
$ProgramsDir = [Environment]::GetFolderPath('Programs')
$StartupLnk  = Join-Path $StartupDir "$AppName.lnk"
$MenuDir     = Join-Path $ProgramsDir $AppName
$MenuLnk     = Join-Path $MenuDir "$AppName.lnk"
$KeyDir      = Join-Path $env:APPDATA $AppName
$KeyFile     = Join-Path $KeyDir 'openai.key'
$LegacyKey   = Join-Path $env:APPDATA "$LegacyName\openai.key"
$MutexName   = "Global\$AppName.SingleInstance"

# ---------------------------------------------------------------------------
# Stopping
# ---------------------------------------------------------------------------

function Stop-SpeakIt {
    # Matches run.py only when it belongs to SpeakIt, or to VoiceType before
    # the rename, so an unrelated Python script called run.py is left alone.
    $all = @(Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" -ErrorAction SilentlyContinue)
    if (-not $all) { return }

    $ours = {
        param($line)
        $line -and (($line -like "*$AppName*") -or ($line -like "*$LegacyName*") -or ($line -like "*$Root*"))
    }

    $live = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { $live[$p.Id] = $true }

    $targets = New-Object System.Collections.Generic.List[object]
    $mains = @($all | Where-Object { $_.CommandLine -like '*run.py*' -and (& $ours $_.CommandLine) })
    foreach ($m in $mains) { $targets.Add($m) }
    $mainIds = @($mains | ForEach-Object { $_.ProcessId })

    # RealtimeSTT transcribes in a spawned worker. Take those too, including
    # orphans from old versions whose parent is already gone.
    foreach ($p in $all) {
        if ($p.CommandLine -notlike '*spawn_main*') { continue }
        $isChild  = $mainIds -contains $p.ParentProcessId
        $isOrphan = (-not $live.ContainsKey($p.ParentProcessId)) -and (& $ours $p.CommandLine)
        if ($isChild -or $isOrphan) { $targets.Add($p) }
    }

    foreach ($t in ($targets | Sort-Object ProcessId -Unique)) {
        Write-Note "stopping PID $($t.ProcessId)"
        try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop } catch {}
    }
    if ($targets.Count -gt 0) { Start-Sleep -Milliseconds 800 }
}

function Remove-Shortcuts([string]$Name) {
    $menu = Join-Path $ProgramsDir $Name
    foreach ($lnk in @((Join-Path $StartupDir "$Name.lnk"), (Join-Path $menu "$Name.lnk"))) {
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Note "removed $lnk"
        }
    }
    if ((Test-Path -LiteralPath $menu) -and -not (Get-ChildItem -LiteralPath $menu -Force)) {
        Remove-Item -LiteralPath $menu -Force
    }
}

# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------

function Set-ApiKey {
    Write-Step 'OpenAI API key'
    Write-Host '    Paste your key (it is not shown), or press Enter to skip.'
    Write-Host '    Get one at https://platform.openai.com/api-keys'
    $secure = Read-Host -AsSecureString '    Key'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($plain)) {
        Write-Note 'skipped. SpeakIt keeps transcribing locally.'
        return
    }
    $plain = $plain.Trim()
    if ($plain -notmatch '^sk-') {
        Write-Warning 'That does not look like an OpenAI key. Saving it anyway.'
    }
    New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    [IO.File]::WriteAllText($KeyFile, $plain, (New-Object Text.UTF8Encoding($false)))
    # Break inheritance so only this account can read it.
    & icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    Write-Note "saved to $KeyFile, readable only by $($env:USERNAME)."
    Write-Note 'The key is read on every request, so there is nothing to restart.'
}

# ---------------------------------------------------------------------------
# Getting the project
# ---------------------------------------------------------------------------

function Test-SafeToReplace([string]$Dir) {
    # The update deletes the old code before copying the new, so refuse any
    # folder that is not already a SpeakIt install.
    if (-not (Test-Path -LiteralPath $Dir)) { return $true }
    if (-not (Get-ChildItem -LiteralPath $Dir -Force)) { return $true }
    return (Test-Path -LiteralPath (Join-Path $Dir 'run.py')) -and
           (Test-Path -LiteralPath (Join-Path $Dir 'install.ps1'))
}

function Get-Project {
    if (-not (Test-SafeToReplace $Root)) {
        throw "$Root already exists and is not a SpeakIt folder. Choose another with -InstallDir, or empty it."
    }
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $zip = Join-Path $env:TEMP "SpeakIt-$stamp.zip"
    $tmp = Join-Path $env:TEMP "SpeakIt-$stamp"
    try {
        Write-Note "from $RepoUrl ($Ref)"
        Invoke-WebRequest -Uri "$RepoUrl/archive/$Ref.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $inner = @(Get-ChildItem -LiteralPath $tmp -Directory)[0]
        if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName 'run.py'))) {
            throw 'The download did not contain SpeakIt.'
        }
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        # Kept across updates. Everything else is replaced, so files removed
        # from the project do not linger in old installs.
        $keep = @('.venv', '.uv', 'config.json', 'logs')
        Get-ChildItem -LiteralPath $Root -Force |
            Where-Object { $keep -notcontains $_.Name } |
            Remove-Item -Recurse -Force
        # Copy, not Move: Move-Item cannot move a folder to another drive.
        Get-ChildItem -LiteralPath $inner.FullName -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Root -Recurse -Force
        }
    } finally {
        Remove-Item -LiteralPath $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Move-FromVoiceType {
    Remove-Shortcuts $LegacyName
    $legacyDir = Join-Path $env:LOCALAPPDATA "Programs\$LegacyName"
    $oldConfig = Join-Path $legacyDir 'config.json'
    $newConfig = Join-Path $Root 'config.json'
    if ((Test-Path -LiteralPath $oldConfig) -and -not (Test-Path -LiteralPath $newConfig)) {
        Copy-Item -LiteralPath $oldConfig -Destination $newConfig
        Write-Note 'kept your settings from VoiceType'
    }
    if ((Test-Path -LiteralPath $legacyDir) -and ($legacyDir -ne $Root)) {
        Write-Note "the old VoiceType folder is still at $legacyDir"
        Write-Note 'delete it once SpeakIt works'
    }
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

function Test-LongPathsEnabled {
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
        return (Get-ItemProperty -Path $key -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled -eq 1
    } catch {
        return $false
    }
}

function Assert-CanInstall {
    if ([Environment]::OSVersion.Version.Major -lt 10) {
        throw 'SpeakIt needs Windows 10 or 11.'
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw 'SpeakIt needs PowerShell 5 or newer, which ships with Windows 10.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'SpeakIt needs 64-bit Windows. PyTorch has no 32-bit build.'
    }
    if ($Root.Length -gt $MaxRootLength -and -not (Test-LongPathsEnabled)) {
        throw ("The install folder path is too long ({0} characters, the limit is {1} on this PC):`n  {2}`nUse a shorter one, for example:  & `$s -InstallDir 'C:\SpeakIt'" -f $Root.Length, $MaxRootLength, $Root)
    }
    # Checked here rather than when downloading, so a folder that cannot be
    # used fails the install before anything running has been stopped.
    if (-not $SelfPath -and -not (Test-SafeToReplace $Root)) {
        throw "$Root already exists and is not a SpeakIt folder. Choose another with -InstallDir, or empty it."
    }
    if ($Root -like '*\OneDrive*') {
        Write-Warning "$Root is inside OneDrive, which will try to sync about a gigabyte of packages. A folder outside it is better."
    }
    if (-not (Test-Path -LiteralPath $VenvDir)) {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))
        $freeGB = $drive.AvailableFreeSpace / 1GB
        if ($freeGB -lt $MinFreeGB) {
            throw ("Only {0:N1} GB free on {1}. SpeakIt needs about {2} GB." -f $freeGB, $drive.Name, $MinFreeGB)
        }
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning "This window is running as administrator. SpeakIt will be set up for the account '$($env:USERNAME)'. If that is not the account you use every day, close this window and run the command in a normal one."
    }
}

function Confirm-VCRuntime {
    # PyTorch and ctranslate2 are built against the Visual C++ runtime. Most
    # PCs have it from some other program; a fresh Windows does not, and the
    # symptom is "DLL load failed" at the very end.
    $system = Join-Path $env:SystemRoot 'System32'
    if ((Test-Path -LiteralPath (Join-Path $system 'msvcp140.dll')) -and
        (Test-Path -LiteralPath (Join-Path $system 'vcruntime140_1.dll'))) {
        return
    }
    Write-Step 'Installing the Microsoft Visual C++ runtime'
    Write-Note 'PyTorch needs it and this PC does not have it. Windows will ask for permission.'
    $url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    $exe = Join-Path $env:TEMP 'vc_redist.x64.exe'
    try {
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
        $p = Start-Process -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
        # 1638: a newer version is already there. 3010: installed, and a
        # restart is recommended but not needed for this.
        if (@(0, 1638, 3010) -notcontains $p.ExitCode) {
            Write-Warning "The runtime installer exited with $($p.ExitCode). If SpeakIt fails to start, install it by hand: $url"
        }
    } catch {
        Write-Warning "Skipped: $($_.Exception.Message). If SpeakIt fails to start, install it by hand: $url"
    } finally {
        Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Python environment
# ---------------------------------------------------------------------------

function Get-Uv {
    $uv = Join-Path $UvDir 'uv.exe'
    if (Test-Path -LiteralPath $uv) {
        $have = ''
        try { $have = "$(& $uv --version)" } catch {}
        if ($have -like "uv $UvVersion*") { return $uv }
    }
    New-Item -ItemType Directory -Force -Path $UvDir | Out-Null
    $zip = Join-Path $env:TEMP "uv-$UvVersion.zip"
    try {
        Invoke-WebRequest -Uri "https://github.com/astral-sh/uv/releases/download/$UvVersion/uv-x86_64-pc-windows-msvc.zip" -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne $UvSha256) {
            throw 'The uv download did not match its published checksum. Try again. If it keeps happening, something on this network is changing downloads.'
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $UvDir -Force
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    return $uv
}

function Test-Venv {
    # Reuse an environment only if uv built it from its own Python. Older
    # installers used whatever Python was on PATH, and those environments
    # break when that Python is upgraded or uninstalled.
    $cfg = Join-Path $VenvDir 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $VenvPy) -or -not (Test-Path -LiteralPath $cfg)) { return $false }
    $match = Select-String -LiteralPath $cfg -Pattern '^home\s*=\s*(.+)$' | Select-Object -First 1
    if (-not $match) { return $false }
    $pythonHome = $match.Matches[0].Groups[1].Value.Trim()
    return $pythonHome.StartsWith((Join-Path $UvDir 'python'), [StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# Shortcuts and launch
# ---------------------------------------------------------------------------

function New-Shortcut([string]$Path) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($Path)
    # pythonw.exe, not python.exe: this is what keeps a console off the screen.
    $sc.TargetPath       = $VenvPyW
    $sc.Arguments        = '"{0}"' -f $EntryFile
    $sc.WorkingDirectory = $Root
    $sc.WindowStyle      = 7
    $sc.Description      = 'SpeakIt - hold Ctrl+Alt to dictate'
    $sc.IconLocation     = "$VenvPyW,0"
    $sc.Save()
    Write-Note "created $Path"
}

function Start-SpeakIt {
    $proc = Start-Process -FilePath $VenvPyW -ArgumentList ('"{0}"' -f $EntryFile) -WorkingDirectory $Root -PassThru
    # The app claims its single-instance mutex as soon as it starts, before
    # the model loads, so this answers "did it start" within a few seconds.
    for ($i = 0; $i -lt 40; $i++) {
        $mutex = $null
        if ([Threading.Mutex]::TryOpenExisting($MutexName, [ref]$mutex)) {
            $mutex.Dispose()
            Write-Note "running (PID $($proc.Id))"
            return
        }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    foreach ($name in @('speakit.log', 'stdout.log')) {
        $log = Join-Path $Root "logs\$name"
        if (Test-Path -LiteralPath $log) {
            Write-Host ''
            Write-Host "    last lines of logs\$name" -ForegroundColor Yellow
            Get-Content -LiteralPath $log -Tail 15 | ForEach-Object { Write-Note $_ }
        }
    }
    throw 'SpeakIt installed but did not start. The log lines above say why.'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Uninstall {
    Write-Step 'Stopping SpeakIt'
    Stop-SpeakIt
    Write-Step 'Removing shortcuts'
    Remove-Shortcuts $AppName
    Remove-Shortcuts $LegacyName
    Write-Host ''
    Write-Host 'SpeakIt will no longer start. Still on disk, delete them if you want them gone:' -ForegroundColor Green
    Write-Host "    $Root"
    foreach ($key in @($KeyFile, $LegacyKey)) {
        if (Test-Path -LiteralPath $key) { Write-Host "    $key" }
    }
    Write-Host '    the speech models, in %USERPROFILE%\.cache\huggingface'
}

function Invoke-Install {
    Assert-CanInstall

    Write-Step 'Stopping any running copy'
    Stop-SpeakIt

    if (-not $SelfPath) {
        Write-Step "Downloading SpeakIt into $Root"
        Get-Project
    }
    if (-not (Test-Path -LiteralPath $EntryFile)) {
        throw "run.py is not in $Root. Run this script from inside the SpeakIt folder."
    }
    Move-FromVoiceType
    Confirm-VCRuntime

    Set-ProcessEnv 'UV_CACHE_DIR' (Join-Path $UvDir 'cache')
    Set-ProcessEnv 'UV_PYTHON_INSTALL_DIR' (Join-Path $UvDir 'python')
    # Slow connections time out on the PyTorch download at uv's default.
    Set-ProcessEnv 'UV_HTTP_TIMEOUT' '300'
    Set-ProcessEnv 'PYTHONUTF8' '1'

    Write-Step 'Getting uv'
    $uv = Get-Uv

    if (-not (Test-Venv)) {
        Write-Step 'Getting Python 3.12 for SpeakIt (your own Python is not touched)'
        Invoke-Native 'Creating the environment' $uv @('venv', '--clear', '--managed-python', '--python', $PythonRequest, $VenvDir)
    }

    Write-Step 'Installing packages (about 1 GB and a few minutes the first time)'
    # The lock file pins every package to the versions this was tested with.
    # --no-build refuses to compile anything from source: every package has a
    # wheel, and the one that did not (halo) ships in vendor/.
    Invoke-Native 'Installing packages' $uv @(
        'pip', 'sync', '--python', $VenvPy, '--no-build',
        '--find-links', (Join-Path $Root 'vendor'),
        (Join-Path $Root 'requirements.lock')
    )

    Write-Step 'Checking the install and downloading the speech models'
    Invoke-Native 'The check' $VenvPy @((Join-Path $Root 'tools\doctor.py'), '--install')

    Write-Step 'Creating shortcuts'
    if ($NoAutostart) {
        if (Test-Path -LiteralPath $StartupLnk) { Remove-Item -LiteralPath $StartupLnk -Force }
        Write-Note 'not starting with Windows (-NoAutostart)'
    } else {
        New-Shortcut $StartupLnk
    }
    New-Shortcut $MenuLnk

    if (-not $NoStart) {
        Write-Step 'Starting SpeakIt'
        Start-SpeakIt
    }

    if ((Test-Path -LiteralPath $KeyFile) -or (Test-Path -LiteralPath $LegacyKey)) {
        $keyState = 'set'
    } else {
        $keyState = 'not set, transcribing locally'
    }
    if ($NoAutostart) { $autoState = 'off' } else { $autoState = 'on' }

    Write-Host ''
    Write-Host '--------------------------------------------------------------' -ForegroundColor Green
    Write-Host ' SpeakIt is installed.' -ForegroundColor Green
    Write-Host '--------------------------------------------------------------' -ForegroundColor Green
    Write-Host @"

  Hold Ctrl+Alt     record while held, release and the text is typed
  Tap  Ctrl+Alt     hands-free, stops when you stop talking
  Any other key     cancels

  Folder       $Root
  OpenAI key   $keyState
  Autostart    $autoState

  The microphone icon in the tray has the settings and Quit.

  Something wrong?   double-click CHECKUP.bat in the folder above
  Remove it          double-click UNINSTALL.bat in the same folder

  To use OpenAI instead of the local model, add a key with:
  powershell -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Maslitsa/SpeakIt/main/install.ps1))) -SetApiKey"
"@
}

$failed = $false
$savedEncoding = $null
Push-Location -LiteralPath $env:TEMP
try {
    # Native programs write UTF-8. Without this, a Cyrillic folder name in an
    # error message comes out as mojibake on a Russian or Kazakh Windows.
    try {
        $savedEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    } catch {}
    # Old Windows 10 builds default to TLS 1.0, which GitHub refuses.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    Set-Content -LiteralPath $LogFile -Value "SpeakIt installer, $(Get-Date -Format s)" -Encoding UTF8
    Write-Log ("PowerShell {0} | {1} | {2} | root {3}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString, $env:PROCESSOR_ARCHITECTURE, $Root)

    if ($Uninstall) {
        Invoke-Uninstall
    } elseif ($SetApiKey) {
        Set-ApiKey
    } else {
        Invoke-Install
    }
} catch {
    $failed = $true
    Write-Log "FAILED: $($_.Exception.Message)"
    Write-Log "$($_.ScriptStackTrace)"
    Write-Host ''
    Write-Host 'SpeakIt was not installed.' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host "  Full log: $LogFile"
    Write-Host "  If you open an issue, attach that file: $RepoUrl/issues"
} finally {
    foreach ($name in $SavedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $SavedEnv[$name], 'Process')
    }
    if ($savedEncoding) {
        try { [Console]::OutputEncoding = $savedEncoding } catch {}
    }
    Pop-Location
}

# Run as a file, a real exit code is useful and closes nothing. Piped into iex
# it would close the user's window, so there it is skipped.
if ($failed -and $SelfPath) { exit 1 }

}
