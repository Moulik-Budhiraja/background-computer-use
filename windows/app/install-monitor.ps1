# The parts of setup that need admin. The app runs this elevated, with one of:
#   -Task    The "keep drawing" task, offered over Remote Desktop: when a session disconnects,
#            Windows stops drawing it, so agents' screenshots freeze. The task moves the session
#            onto the computer's own display (tscon), where it keeps drawing; the app locks it as
#            soon as it arrives.
#   -Driver  The open-source Virtual Display Driver (MIT, github.com/VirtualDrivers/Virtual-Display-Driver),
#            for the agent screen the user can turn on. The app writes its settings
#            (C:\VirtualDisplayDriver\vdd_settings.xml) first. Follows the project's own
#            "Community Scripts/silent-install.ps1", with the downloads pinned by SHA-256.
#   -Remove  Uninstall both, and what older versions left: the driver and its monitors, the
#            certificates trusted to install it, the task and its script.
param([switch]$Task, [switch]$Driver, [switch]$Remove)
$ErrorActionPreference = "Stop"
$taskName = "Background Computer Use keep drawing"
# Not $env:ProgramFiles: the user can set that for their own programs, this one included.
$taskDir = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "Background Computer Use"

# The certificates in the driver's catalog (SignPath Foundation's, up to GlobalSign's root).
function Get-CatalogCerts([string]$cat) {
  $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
  $certs.Import([System.IO.File]::ReadAllBytes($cat))
  $certs
}
function Remove-Trust([string]$cat) {
  foreach ($c in (Get-CatalogCerts $cat)) {
    $path = "Cert:\LocalMachine\TrustedPublisher\$($c.Thumbprint)"
    if (Test-Path $path) { Remove-Item $path; Write-Output "untrusted $($c.Subject)" }
  }
}

if ($Remove) {
  $ErrorActionPreference = "Continue"
  $cat = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" -Recurse -Filter mttvdd.cat -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cat) { Remove-Trust $cat.FullName }
  foreach ($d in (Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -like '*\mttvdd.inf' })) {
    pnputil /delete-driver $d.Driver /uninstall /force | Out-String | Write-Output
  }
  Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' } | ForEach-Object {
    pnputil /remove-device $_.InstanceId | Out-String | Write-Output
  }
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $taskDir, 'C:\VirtualDisplayDriver' -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

if ($Task) {
  # The task runs as SYSTEM, so its script goes where only admins can change it.
  New-Item -ItemType Directory -Force $taskDir | Out-Null
  $taskScript = Join-Path $taskDir "keep-drawing.ps1"
  $taskScriptText = @'
# Run as SYSTEM by the "Background Computer Use keep drawing" task when a session disconnects.
# If Background Computer Use runs in that session and nobody is signed in at the computer itself,
# move the session onto the computer's own display so agents' windows keep drawing. The app
# locks the session as soon as it arrives there.
param([int]$SessionId)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class BcuWts {
  [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int infoClass, out IntPtr buffer, out int bytes);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
  [DllImport("kernel32.dll")] public static extern int WTSGetActiveConsoleSessionId();
  public static int State(int s) { IntPtr b; int n; if (!WTSQuerySessionInformationW(IntPtr.Zero, s, 8, out b, out n)) return -1; int v = Marshal.ReadInt32(b); WTSFreeMemory(b); return v; }
  public static string User(int s) { IntPtr b; int n; if (!WTSQuerySessionInformationW(IntPtr.Zero, s, 5, out b, out n)) return null; string v = Marshal.PtrToStringUni(b); WTSFreeMemory(b); return v; }
}
"@
Start-Sleep -Seconds 2
# Still disconnected (4 = WTSDisconnected), not reconnected meanwhile.
if ([BcuWts]::State($SessionId) -ne 4) { exit 0 }
if (-not (Get-Process BackgroundComputerUse -ErrorAction SilentlyContinue | Where-Object SessionId -eq $SessionId)) { exit 0 }
# Someone signed in at the computer keeps it.
$console = [BcuWts]::WTSGetActiveConsoleSessionId()
if ($console -ne $SessionId -and [BcuWts]::User($console)) { exit 0 }
tscon.exe $SessionId /dest:console
'@
  $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Keeps Background Computer Use's agents working after Remote Desktop disconnects.</Description></RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;&lt;Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;*[System[EventID=24]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries><Value name="SessionID">Event/UserData/EventXML/SessionID</Value></ValueQueries>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$taskScript" -SessionId `$(SessionID)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
  # Written last: the app checks for this file to know the task is there (users can't query a SYSTEM task).
  Set-Content -Path $taskScript -Value $taskScriptText -Encoding UTF8
  Write-Output "keep-drawing task registered"
}

if ($Driver) {
  # Already installed: installing again adds a second device, not a fix.
  if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY\*" -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }) {
    Write-Output "already installed"
    exit 0
  }
  if (-not (Test-Path 'C:\VirtualDisplayDriver\vdd_settings.xml')) { throw "the app writes C:\VirtualDisplayDriver\vdd_settings.xml first" }
  # Windows PowerShell 5.1 may not offer TLS 1.2, which GitHub requires.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  # The releases this was tested with, pinned by SHA-256: nefcon 1.14.0 and Virtual Display Driver 25.7.23.
  $release = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23"
  $NefConURL = "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip"
  $NefConHash = "a15557da24a9efca203158de3b43b0eaf982db231f0194031f1ed428bc13e669"
  # The computer's own processor, even when this PowerShell runs emulated.
  $arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
  switch ($arch) {
    'AMD64' { $DriverURL = "$release/VirtualDisplayDriver-x86.Driver.Only.zip"; $DriverHash = "e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a"; $NefConDir = "x64" }
    'ARM64' { $DriverURL = "$release/VirtualDisplayDriver-ARM64.Driver.Only.zip"; $DriverHash = "dcd487161469c726bab60f174a7e7f70ee02afd437cad0d5c0e6755953de5a25"; $NefConDir = "ARM64" }
    default { throw "the Virtual Display Driver isn't made for this PC's processor ($arch)" }
  }
  # The one certificate trusted for the install: SignPath Foundation's, which signs the driver's catalog.
  $Publisher = "3CF8CF26D8BA266C3A483AB7D26D4A818E317D76"
  # Downloaded where only admins can write, not the user's TEMP, which their programs can change while this runs.
  $tmp = Join-Path $taskDir "driver-download"
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $ProgressPreference = 'SilentlyContinue'
  function Get-Pinned([string]$url, [string]$hash, [string]$dir) {
    $zip = "$dir.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($got -ne $hash) { throw "$url isn't the expected file (SHA-256 $got)" }
    Expand-Archive $zip -DestinationPath $dir -Force
  }

  $trusted = "Cert:\LocalMachine\TrustedPublisher\$Publisher"
  $added = $false
  try {
    Get-Pinned $NefConURL $NefConHash "$tmp\nefcon"
    Get-Pinned $DriverURL $DriverHash "$tmp\driver"
    # The package is signed by SignPath. Trust its certificate just long enough to
    # install it without a prompt, then take it out again.
    $cat = Get-ChildItem "$tmp\driver" -Recurse -Filter mttvdd.cat | Select-Object -First 1
    $cert = Get-CatalogCerts $cat.FullName | Where-Object { $_.Thumbprint -eq $Publisher } | Select-Object -First 1
    if (-not $cert) { throw "the driver's catalog doesn't carry the expected publisher's certificate" }
    if (-not (Test-Path $trusted)) {
      $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
      $store.Open("ReadWrite")
      $store.Add($cert)
      $store.Close()
      $added = $true
    }
    $inf = Get-ChildItem "$tmp\driver" -Recurse -Filter MttVDD.inf | Select-Object -First 1
    & "$tmp\nefcon\$NefConDir\nefconw.exe" install $inf.FullName "Root\MttVDD"
    Start-Sleep -Seconds 5
  } finally {
    if ($added) { Remove-Item $trusted -ErrorAction SilentlyContinue }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem $taskDir -ErrorAction SilentlyContinue)) { Remove-Item $taskDir -ErrorAction SilentlyContinue }
  }
  Get-PnpDevice -Class Display | Format-Table -AutoSize Status, FriendlyName, InstanceId | Out-String | Write-Output
}
exit 0
