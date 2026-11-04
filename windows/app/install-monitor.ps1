# The admin part of setup. Run elevated (the app's setup does).
# 1. The "keep drawing" task: when a Remote Desktop session disconnects, Windows stops drawing it,
#    so agents' screenshots freeze. The task moves the session onto the computer's own display
#    (tscon), where it keeps drawing; the app locks it as soon as it arrives.
# 2. The open-source Virtual Display Driver (MIT, github.com/VirtualDrivers/Virtual-Display-Driver)
#    with four 1600x1000 monitors, one per agent session. Follows the project's own
#    "Community Scripts/silent-install.ps1".
$ErrorActionPreference = "Stop"
Write-Output "whoami: $(whoami /groups | Select-String 'Mandatory Label')"

# The task runs as SYSTEM, so its script goes where only admins can change it.
$taskDir = Join-Path $env:ProgramFiles "Background Computer Use"
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
Register-ScheduledTask -TaskName "Background Computer Use keep drawing" -Xml $taskXml -Force | Out-Null
# Written last: the app checks for this file to know the task is there (users can't query a SYSTEM task).
Set-Content -Path $taskScript -Value $taskScriptText -Encoding UTF8
Write-Output "keep-drawing task registered"

# Already installed: installing again adds a second device, not a fix.
if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY\*" -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }) {
  Write-Output "already installed"
  exit 0
}
$NefConURL = "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip"
$DriverURL = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip"
$SettingsURL = "https://raw.githubusercontent.com/VirtualDrivers/Virtual-Display-Driver/master/Virtual%20Display%20Driver%20(HDR)/vdd_settings.xml"

# Settings first: four monitors, one mode, so Windows can't pick another.
$cfgDir = "C:\VirtualDisplayDriver"
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
[xml]$xml = (Invoke-WebRequest -Uri $SettingsURL -UseBasicParsing).Content
$xml.vdd_settings.monitors.count = "4"
$res = $xml.vdd_settings.resolutions
$res.RemoveAll()
$r = $xml.CreateElement("resolution")
foreach ($kv in @(@("width", "1600"), @("height", "1000"), @("refresh_rate", "60"))) {
  $e = $xml.CreateElement($kv[0]); $e.InnerText = $kv[1]; [void]$r.AppendChild($e)
}
[void]$res.AppendChild($r)
$g = $xml.vdd_settings.global
$g.RemoveAll()
$e = $xml.CreateElement("g_refresh_rate"); $e.InnerText = "60"; [void]$g.AppendChild($e)
$xml.Save("$cfgDir\vdd_settings.xml")
Write-Output "wrote $cfgDir\vdd_settings.xml"

$tmp = Join-Path $env:TEMP "VDDInstall"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Invoke-WebRequest -Uri $NefConURL -OutFile "$tmp\nefcon.zip" -UseBasicParsing
Expand-Archive "$tmp\nefcon.zip" -DestinationPath $tmp -Force
Invoke-WebRequest -Uri $DriverURL -OutFile "$tmp\driver.zip" -UseBasicParsing
Expand-Archive "$tmp\driver.zip" -DestinationPath $tmp -Force
Get-ChildItem $tmp -Recurse -Include *.inf, *.cat, *.dll | ForEach-Object { Write-Output "  $($_.FullName)" }

# The package is signed by SignPath; trust its certificates for driver installs.
$cat = Get-ChildItem $tmp -Recurse -Filter mttvdd.cat | Select-Object -First 1
$certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$certs.Import([System.IO.File]::ReadAllBytes($cat.FullName))
foreach ($c in $certs) {
  $f = Join-Path $tmp "$($c.Thumbprint).cer"
  [System.IO.File]::WriteAllBytes($f, $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
  certutil -f -addstore TrustedPublisher $f | Out-String | Write-Output
}

$inf = Get-ChildItem $tmp -Recurse -Filter MttVDD.inf | Select-Object -First 1
& "$tmp\x64\nefconw.exe" install $inf.FullName "Root\MttVDD"
Start-Sleep -Seconds 10
Get-PnpDevice -Class Display | Format-Table -AutoSize Status, FriendlyName, InstanceId | Out-String | Write-Output
