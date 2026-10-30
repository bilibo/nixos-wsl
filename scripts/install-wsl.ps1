<#
.SYNOPSIS
  Provision NixOS-WSL from this host flake.

.DESCRIPTION
  Run from a checkout of nixos-wsl on Windows.
  Idempotent: every step checks before it acts, so rerunning is the update
  path. Windows only registers the distro and hands over; everything else runs
  inside it, and nothing is read from a Windows drive.

    1. distro      only when the distro is not registered: resolve the latest
                   NixOS-WSL release (or -Tag), download nixos.wsl into Downloads,
                   verify it against the published sha256, wsl --install --from-file.
    2. system      only when /etc/nixos is not yet a git checkout: scripts/wsl/
                   bootstrap.sh is piped into the distro on stdin; it clones
                   -HostRepo (a git URL, by default this checkout's origin),
                   builds nixosConfigurations.<Output> as the default user and
                   switches to it. From then on the system is updated inside
                   the distro (nh os switch in /etc/nixos); a rerun does 3-7.
                   -NoSwitch builds but does not activate, and prints the two
                   commands that would; it also skips steps 6 and 7. Step 3
                   still writes .wslconfig, which applies at the next shutdown.
    3. .wslconfig  if the host configuration carries windows/wslconfig, it becomes
                   %USERPROFILE%\.wslconfig (a differing existing file is backed up).
    4. VS Code     installs windows/vscode-extensions.txt with `code --install-extension`;
                   writes windows/vscode-settings.json to the user settings only when
                   none exists, otherwise prints the merge hint.
    5. font        installs CaskaydiaMono Nerd Font Mono for the current user
                   (nerd-fonts release, SHA-256 checked) and sets it as Windows
                   Terminal's default font when profiles.defaults is empty
                   (after a backup); otherwise prints the one setting to make.
    6. restart     wsl --shutdown, so .wslconfig and wsl.conf apply.
    7. verify      scripts/wsl/verify.sh: user, DNS, HTTPS, Nix, the sandbox
                   prerequisites and the boxed-off Windows side.

.PARAMETER HostRepo
  Git URL of the host configuration flake. Default: this checkout's origin
  remote (git -C <checkout> remote get-url origin). A folder path is refused.
  Used by the first install only (the clone); a rerun does not need it. A
  public URL: no credential crosses into the distro. A private configuration
  is taken over from inside after the install (README).
.PARAMETER Output
  The nixosConfigurations attribute to switch to. Default: nixos-wsl.
.PARAMETER Tag
  NixOS-WSL release tag to install from. Default: latest.
.PARAMETER NoSwitch
  Build the system but do not activate it; the commands to do so are printed.
  Skips the restart and verify steps; .wslconfig is still written.
.PARAMETER DistroName
  WSL distribution name. Default: NixOS.
.PARAMETER InstallDir
  Where the distribution's disk lives. Default: %USERPROFILE%\WSL\<DistroName>.
.PARAMETER SkipVerify
  Do not run scripts/wsl/verify.sh after the restart.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1 -HostRepo https://github.com/you/nixos-config
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1 -NoSwitch
#>
[CmdletBinding()]
param(
  [string] $HostRepo = '',
  [string] $Output = 'nixos-wsl',
  [string] $Tag = 'latest',
  [switch] $NoSwitch,
  [string] $DistroName = 'NixOS',
  [string] $InstallDir = '',
  [switch] $SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false   # stdin to wsl.exe: UTF-8, no BOM
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($InstallDir -eq '') { $InstallDir = Join-Path $env:USERPROFILE "WSL\$DistroName" }
$ReleaseApi   = 'https://api.github.com/repos/nix-community/NixOS-WSL/releases'
$ScriptsDir   = $PSScriptRoot                          # <checkout>\scripts
$Checkout     = Split-Path -Parent $ScriptsDir         # this nixos-wsl checkout
$WslConfigDst = Join-Path $env:USERPROFILE '.wslconfig'
$Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir       = Join-Path $env:TEMP 'nixos-wsl'
# wsl --exec runs without the NixOS PATH, and NixOS has no /bin/cat.
$Cat = '/run/current-system/sw/bin/cat'
# The Nerd Font family the font step installs (GDI name of the Mono variant).
$FontFace = 'CaskaydiaMono NFM'
$Log          = Join-Path $LogDir "install-wsl-$Stamp.log"

function Step([string] $msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Info([string] $msg) { Write-Host "   $msg" }

function Invoke-Native {
  param([string] $Exe, [string[]] $Arguments)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Exe @Arguments | Out-Host
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Invoke-Wsl([string[]] $Arguments) {
  $code = Invoke-Native 'wsl.exe' $Arguments
  if ($code -ne 0) { throw "wsl.exe $($Arguments -join ' ') exited with $code" }
}

# Capture a command's stdout from inside the distro (UTF-8 thanks to WSL_UTF8).
function Read-Wsl([string[]] $Arguments) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { return @(& wsl.exe @Arguments 2>$null | ForEach-Object { "$_" }) }
  finally { $ErrorActionPreference = $prev }
}

# A checkout's origin URL, or '' when it has none or git.exe is not on PATH.
function Get-OriginUrl([string] $Dir) {
  if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) { return '' }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $url = @(& git.exe -C $Dir remote get-url origin 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -eq 0 -and $url.Count -eq 1) { return $url[0] }
    return ''
  }
  finally { $ErrorActionPreference = $prev }
}

New-Item -ItemType Directory -Force $LogDir | Out-Null
$transcribing = $false
try { Start-Transcript -Path $Log | Out-Null; $transcribing = $true } catch { }

try {
  # ---- 0. preflight --------------------------------------------------------
  Step 'Preflight'
  # Only the first install (the clone) needs the host repo; step 2 insists then.
  if ($HostRepo -eq '') {
    $HostRepo = Get-OriginUrl $Checkout
    $hostFrom = 'this checkout''s origin'
  } else {
    $hostFrom = '-HostRepo'
  }
  if ($HostRepo -ne '' -and ($HostRepo -match '^([A-Za-z]:|[\\/.~])' -or (Test-Path $HostRepo -PathType Container) -or
      ($HostRepo -notmatch '://' -and $HostRepo -notmatch '^git@'))) {
    throw "-HostRepo must be a git URL (https://..., ssh://... or git@host:path), not a folder: $HostRepo"
  }
  Info "checkout:  $Checkout"
  Info "host repo: $(if ($HostRepo -ne '') { "$HostRepo  ($hostFrom)" } else { '(none: no origin remote; only a first install needs -HostRepo)' })"
  Info "output:    $Output$(if ($NoSwitch) { '  (build only)' })"
  Info "distro:    $DistroName at $InstallDir"
  Info "image:     NixOS-WSL release '$Tag' (fetched only if the distro is missing)"
  $build = [Environment]::OSVersion.Version.Build
  if ($build -lt 22621) {
    Write-Warning "Windows build $build is older than 22621 (22H2); mirrored networking in .wslconfig needs 22H2 or newer."
  }
  if ((Invoke-Native 'wsl.exe' @('--version')) -ne 0) {
    throw "WSL is not installed or too old. Run 'wsl --install --no-distribution', reboot, then rerun."
  }
  # Only bootstrap.sh is read from this checkout; it is piped into the distro.
  # verify.sh runs from /etc/nixos inside the distro.
  if (-not (Test-Path (Join-Path $ScriptsDir 'wsl\bootstrap.sh'))) { throw 'missing scripts\wsl\bootstrap.sh; run from a checkout of nixos-wsl' }

  # ---- 1. distro (image fetched only when needed) --------------------------
  Step "Distro $DistroName"
  $registered = Read-Wsl @('--list', '--quiet') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if ($registered -contains $DistroName) {
    Info 'already registered, skipping image download and install'
  } else {
    $api = if ($Tag -eq 'latest') { "$ReleaseApi/latest" } else { "$ReleaseApi/tags/$Tag" }
    Info "resolving NixOS-WSL release '$Tag'"
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'nixos-wsl install-wsl.ps1' }
    $imgAsset = @($rel.assets | Where-Object { $_.name -eq 'nixos.wsl' })
    $sumAsset = @($rel.assets | Where-Object { $_.name -eq 'nixos.wsl.sha256' })
    if ($imgAsset.Count -ne 1 -or $sumAsset.Count -ne 1) {
      throw "release $($rel.tag_name) does not carry nixos.wsl + nixos.wsl.sha256"
    }
    Info "release $($rel.tag_name), published $($rel.published_at)"

    $imageDir  = Join-Path $env:USERPROFILE "Downloads\nixos-wsl-$($rel.tag_name)"
    $imagePath = Join-Path $imageDir 'nixos.wsl'
    $sumPath   = Join-Path $imageDir 'nixos.wsl.sha256'
    New-Item -ItemType Directory -Force $imageDir | Out-Null

    if ((Invoke-Native 'curl.exe' @('-sSL', '--fail', '-o', $sumPath, $sumAsset[0].browser_download_url)) -ne 0) {
      throw 'checksum download failed'
    }
    $expected = ((Get-Content -Raw $sumPath) -split '\s+')[0].ToLower()
    if (Test-Path $imagePath) {
      Info "present: $imagePath"
    } else {
      Info ("downloading nixos.wsl ({0:N0} MB)" -f ($imgAsset[0].size / 1MB))
      if ((Invoke-Native 'curl.exe' @('-sSL', '--fail', '-o', $imagePath, $imgAsset[0].browser_download_url)) -ne 0) {
        throw 'image download failed'
      }
    }
    $actual = (Get-FileHash $imagePath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
      throw "sha256 mismatch for $imagePath`n  published $expected`n  got       $actual`nDelete the file and rerun."
    }
    Info 'sha256 matches the published checksum'

    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    Invoke-Wsl @('--install', '--from-file', $imagePath, '--name', $DistroName, '--location', $InstallDir, '--no-launch')
    Info "installed $($rel.tag_name) into $InstallDir"
  }

  # ---- 2. system (first install only) --------------------------------------
  $switchArg = if ($NoSwitch) { '--no-switch' } else { '--switch' }
  $isCheckout = (Invoke-Native 'wsl.exe' @('-d', $DistroName, '-u', 'root', '--exec', '/bin/sh', '-c', 'test -d /etc/nixos/.git')) -eq 0
  if ($isCheckout) {
    Step 'System'
    Info '/etc/nixos is already a checkout; update it inside the distro: cd /etc/nixos && nh os switch'
  } else {
    if ($HostRepo -eq '') {
      throw 'a first install needs the host repo: this checkout has no origin remote (or git.exe is not on PATH); pass -HostRepo <git url>'
    }
    Step "System: first install, /etc/nixos <- $HostRepo -> #$Output"
    # bootstrap.sh goes in on stdin and runs from a temp file, so nothing is read
    # from a Windows drive and no child of the script can swallow its stdin.
    # sed drops a UTF-8 BOM Windows PowerShell 5.1 may prepend, tr the CRs.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      Get-Content -Raw (Join-Path $ScriptsDir 'wsl\bootstrap.sh') | & wsl.exe -d $DistroName -u root --exec /bin/sh -lc "sed '1s/^\xef\xbb\xbf//' | tr -d '\r' > /tmp/nixos-wsl-bootstrap.sh && sh /tmp/nixos-wsl-bootstrap.sh $HostRepo $Output $switchArg"
      $bootstrapCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $prev
    }
    if ($bootstrapCode -ne 0) { throw "bootstrap.sh exited with $bootstrapCode" }
  }

  # ---- 3. .wslconfig from the host configuration ---------------------------
  Step '.wslconfig'
  $src = @(Read-Wsl @('-d', $DistroName, '-u', 'root', '--exec', $Cat, '/etc/nixos/windows/wslconfig'))
  if ($src.Count -eq 0) {
    Info 'host configuration has no windows/wslconfig; leaving the current file alone'
  } else {
    $text = ($src -join "`n") + "`n"
    $same = (Test-Path $WslConfigDst) -and ((Get-Content -Raw $WslConfigDst) -eq $text)
    if ($same) {
      Info "unchanged: $WslConfigDst"
    } else {
      if (Test-Path $WslConfigDst) {
        Copy-Item $WslConfigDst "$WslConfigDst.bak-$Stamp"
        Info "existing file backed up to $WslConfigDst.bak-$Stamp"
      }
      [IO.File]::WriteAllText($WslConfigDst, $text)
      Info "written: $WslConfigDst"
    }
  }

  # ---- 4. VS Code: extensions + client settings ---------------------------
  Step 'VS Code'
  $extText = @(Read-Wsl @('-d', $DistroName, '-u', 'root', '--exec', $Cat, '/etc/nixos/windows/vscode-extensions.txt'))
  $setText = @(Read-Wsl @('-d', $DistroName, '-u', 'root', '--exec', $Cat, '/etc/nixos/windows/vscode-settings.json'))
  $extIds = @($extText | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
  $codeCmd = Get-Command code.cmd -ErrorAction SilentlyContinue
  if (-not $codeCmd) { $codeCmd = Get-Command code -ErrorAction SilentlyContinue }
  $codeSettings = Join-Path $env:APPDATA 'Code\User\settings.json'

  if ($extIds.Count -eq 0) {
    Info 'host configuration has no windows/vscode-extensions.txt; extensions skipped'
  } elseif (-not $codeCmd) {
    Info 'VS Code CLI (code) not found; install these extensions yourself:'
    $extIds | ForEach-Object { Info "  $_" }
  } else {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $added = 0
    $present = 0
    try {
      $have = @(& $codeCmd.Source --list-extensions 2>$null | ForEach-Object { "$_".Trim().ToLower() })
      foreach ($id in $extIds) {
        if ($have -contains $id.ToLower()) { $present++; continue }
        Info "installing $id"
        & $codeCmd.Source --install-extension $id 2>&1 | Out-Host
        if ($LASTEXITCODE -eq 0) { $added++ } else { Write-Warning "could not install $id" }
      }
    } finally {
      $ErrorActionPreference = $prev
    }
    Info "extensions: $added installed, $present already present"
  }

  if ($setText.Count -eq 0) {
    Info 'host configuration has no windows/vscode-settings.json; client settings skipped'
  } elseif (-not (Test-Path $codeSettings)) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $codeSettings) | Out-Null
    [IO.File]::WriteAllText($codeSettings, (($setText -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    Info "written: $codeSettings (there was none)"
  } elseif ((Get-Content -Raw $codeSettings) -match [regex]::Escape('"remote.WSL.experimental.scriptLessStartup"')) {
    Info "$codeSettings already has scriptLessStartup; left alone"
  } else {
    Info "$codeSettings exists and is never rewritten. Merge the keys of"
    Info "  $Checkout\windows\vscode-settings.json into it (scriptLessStartup is required)."
  }

  if ((Test-Path $codeSettings) -and -not ((Get-Content -Raw $codeSettings) -match [regex]::Escape('"terminal.integrated.fontFamily"'))) {
    Info 'for the prompt icons in the VS Code terminal, add to that file:'
    Info "  `"terminal.integrated.fontFamily`": `"'$FontFace'`""
  }

  # ---- 5. Nerd Font for the prompt icons -----------------------------------
  # Per-user install (no admin): the files go to the user's font folder and
  # are registered under HKCU, which Windows 10 1809 and later load.
  Step 'Font'
  $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
  $fontKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
  $present = @(Get-ChildItem $fontDir -Filter 'CaskaydiaMonoNerdFontMono-*.ttf' -ErrorAction SilentlyContinue)
  if ($present.Count -gt 0) {
    Info "present: $($present.Count) CaskaydiaMono Nerd Font Mono files in $fontDir"
  } else {
    $nfRel = Invoke-RestMethod -Uri 'https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest' -Headers @{ 'User-Agent' = 'nixos-wsl install-wsl.ps1' }
    $zipAsset = @($nfRel.assets | Where-Object { $_.name -eq 'CascadiaMono.zip' })
    $sumAsset = @($nfRel.assets | Where-Object { $_.name -eq 'SHA-256.txt' })
    if ($zipAsset.Count -ne 1 -or $sumAsset.Count -ne 1) {
      throw "nerd-fonts release $($nfRel.tag_name) does not carry CascadiaMono.zip + SHA-256.txt"
    }
    $work = Join-Path $env:TEMP "nixos-wsl-font-$($nfRel.tag_name)"
    New-Item -ItemType Directory -Force $work | Out-Null
    $zipPath = Join-Path $work 'CascadiaMono.zip'
    $sumPath = Join-Path $work 'SHA-256.txt'
    Info ("downloading CascadiaMono.zip ({0:N0} MB) from nerd-fonts {1}" -f ($zipAsset[0].size / 1MB), $nfRel.tag_name)
    foreach ($pair in @(@($sumPath, $sumAsset[0].browser_download_url), @($zipPath, $zipAsset[0].browser_download_url))) {
      if ((Invoke-Native 'curl.exe' @('-sSL', '--fail', '-o', $pair[0], $pair[1])) -ne 0) { throw "download failed: $($pair[1])" }
    }
    $sumLine = @(Get-Content $sumPath | Where-Object { $_ -match '\sCascadiaMono\.zip\s*$' })
    if ($sumLine.Count -ne 1) { throw 'SHA-256.txt has no line for CascadiaMono.zip' }
    $expected = ($sumLine[0].Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { throw "sha256 mismatch for $zipPath`n  published $expected`n  got       $actual" }
    Info 'sha256 matches the published checksum'
    $unpacked = Join-Path $work 'unpacked'
    Expand-Archive -Path $zipPath -DestinationPath $unpacked -Force
    New-Item -ItemType Directory -Force $fontDir | Out-Null
    if (-not (Test-Path $fontKey)) { New-Item -Force $fontKey | Out-Null }
    Add-Type -Namespace NixosWsl -Name Gdi -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
'@
    $files = @(Get-ChildItem $unpacked -Filter 'CaskaydiaMonoNerdFontMono-*.ttf')
    foreach ($f in $files) {
      $dst = Join-Path $fontDir $f.Name
      Copy-Item $f.FullName $dst -Force
      $style = $f.BaseName -replace '^CaskaydiaMonoNerdFontMono-', ''
      New-ItemProperty -Path $fontKey -Name "$FontFace $style (TrueType)" -Value $dst -PropertyType String -Force | Out-Null
      [void][NixosWsl.Gdi]::AddFontResource($dst)   # usable in this session without signing out
    }
    Info "installed $($files.Count) font files to $fontDir"
  }

  # Windows Terminal: the font goes into profiles.defaults of its settings.json,
  # so it covers the distro's profile across re-registrations. A fragment
  # cannot do it: fragments may only change Terminal's built-in and generated
  # profiles, and WSL publishes the distro's profile through its own fragment.
  # The file is edited only in the one safe case, an empty "defaults": {}
  # object, after a backup; otherwise the setting is printed for you.
  $oldFragDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\nixos-wsl'
  if (Test-Path $oldFragDir) { Remove-Item -Recurse -Force $oldFragDir; Info "removed the old fragment $oldFragDir (it had no effect)" }
  $wtSettings = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $wtSettings) {
    Info "Windows Terminal settings not found; set Settings > Defaults > Appearance > Font face: $FontFace"
  } else {
    $wtText = [IO.File]::ReadAllText($wtSettings)
    $emptyDefaults = '"defaults"\s*:\s*\{\s*\}'
    if ($wtText -match [regex]::Escape("`"$FontFace`"")) {
      Info "Windows Terminal already uses $FontFace ($wtSettings)"
    } elseif ($wtText -match $emptyDefaults) {
      Copy-Item $wtSettings "$wtSettings.bak-$Stamp"
      $wtText = [regex]::Replace($wtText, $emptyDefaults, "`"defaults`": { `"font`": { `"face`": `"$FontFace`" } }", 1)
      [IO.File]::WriteAllText($wtSettings, $wtText, (New-Object System.Text.UTF8Encoding $false))
      Info "Windows Terminal: profiles.defaults font set to $FontFace (backup: $wtSettings.bak-$Stamp)"
    } else {
      Info "Windows Terminal's profiles.defaults is not empty, so it is left alone. Set the font once:"
      Info "  Settings > Defaults > Appearance > Font face: $FontFace"
    }
  }

  # ---- 6. restart + 7. verify ----------------------------------------------
  if ($NoSwitch) {
    Step 'Not restarting: nothing was activated'
  } else {
    Step 'Restart WSL (apply .wslconfig and wsl.conf)'
    Invoke-Wsl @('--shutdown')
    Info 'VM stopped; the next launch picks up the new settings'
    if (-not $SkipVerify) {
      Step 'Verify'
      Invoke-Wsl @('-d', $DistroName, '--exec', '/bin/sh', '-lc', 'sh /etc/nixos/scripts/wsl/verify.sh')
    }
  }

  Step 'Done'
  Info "system:  $Output$(if ($NoSwitch) { ' (built, not activated)' })"
  Info "log:     $Log"
  Info ''
  Info 'VS Code: see the VS Code step above (scriptLessStartup, settings, extensions).'
  Info 'Font: restart Windows Terminal and VS Code to pick up the Nerd Font.'
  Info ''
  Info 'Claude Code comes from its VS Code extension: open a folder over Remote-WSL'
  Info 'and it runs its bundled binary inside the distro (README).'
}
catch {
  Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "log: $Log"
  if ($transcribing) { Stop-Transcript | Out-Null }
  exit 1
}
if ($transcribing) { Stop-Transcript | Out-Null }
exit 0
