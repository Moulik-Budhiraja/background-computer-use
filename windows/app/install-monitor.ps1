# Install the open-source Virtual Display Driver (MIT, github.com/VirtualDrivers/Virtual-Display-Driver)
# with four 1600x1000 monitors, one per agent session. Run elevated (the app's setup does).
# Follows the project's own "Community Scripts/silent-install.ps1".
$ErrorActionPreference = "Stop"
Write-Output "whoami: $(whoami /groups | Select-String 'Mandatory Label')"

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
