# The Windows release build, run by app-hosting's release-windows.yml
# (apps.json builds.windows.command) from the repo root, in PowerShell 7:
# builds the app, signs its exes when APPS_SIGN_SCRIPT is set, and packs them
# into windows/dist/BackgroundComputerUse-Setup-$VERSION.exe. Installs Rust
# for the build if the machine doesn't have it.
#
#   $env:VERSION = '1.2.3'; pwsh -File windows/build.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$version = if ($env:VERSION) { $env:VERSION } else { (Get-Content (Join-Path $PSScriptRoot '..\VERSION')).Trim() }
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw "VERSION must look like 1.2.3, not '$version'" }

function Run([string]$what) {
  if ($LASTEXITCODE) { throw "$what failed (exit $LASTEXITCODE)" }
}

Push-Location $PSScriptRoot
try {
  # BCU_FRESH_RUST=1 installs it anyway (CI, to try what the release runner does).
  if ($env:BCU_FRESH_RUST -or -not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $tools = Join-Path ([IO.Path]::GetTempPath()) 'bcu-rust'
    $env:RUSTUP_HOME = Join-Path $tools 'rustup'
    $env:CARGO_HOME = Join-Path $tools 'cargo'
    $env:PATH = "$(Join-Path $env:CARGO_HOME 'bin');$env:PATH"
    if (-not (Test-Path (Join-Path $env:CARGO_HOME 'bin\cargo.exe'))) {
      Write-Host '==> installing Rust'
      New-Item -ItemType Directory $tools -Force | Out-Null
      $init = Join-Path $tools 'rustup-init.exe'
      Invoke-WebRequest 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $init -UseBasicParsing
      & $init -y --no-modify-path --profile minimal --default-toolchain stable | Out-Host
      Run 'installing Rust'
    }
  }

  $env:BCU_VERSION = $version
  Write-Host "==> building $version"
  cargo build --release --locked -p background-computer-use -p bcu | Out-Host
  Run 'cargo build'

  # What the installer installs.
  $payload = Join-Path $PSScriptRoot 'target\payload'
  Remove-Item $payload -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory (Join-Path $payload 'skills') -Force | Out-Null
  Copy-Item 'target\release\BackgroundComputerUse.exe', 'target\release\bcu.exe', 'app\install-monitor.ps1' $payload
  Copy-Item '..\skills\background-computer-use' (Join-Path $payload 'skills') -Recurse
  if ($env:APPS_SIGN_SCRIPT) {
    Write-Host '==> signing the app'
    & pwsh -NoProfile -NonInteractive -File $env:APPS_SIGN_SCRIPT (Join-Path $payload 'BackgroundComputerUse.exe') (Join-Path $payload 'bcu.exe') | Out-Host
    Run 'signing'
  }

  $env:BCU_PAYLOAD = $payload
  cargo build --release --locked -p bcu-setup | Out-Host
  Run 'building the installer'
  $dist = Join-Path $PSScriptRoot 'dist'
  New-Item -ItemType Directory $dist -Force | Out-Null
  $installer = Join-Path $dist "BackgroundComputerUse-Setup-$version.exe"
  Copy-Item 'target\release\BackgroundComputerUse-Setup.exe' $installer -Force
  Write-Host "==> $installer"
} finally {
  Pop-Location
}
