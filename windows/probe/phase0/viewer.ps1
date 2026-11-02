# The expanded view: opens it on one agent's monitor and screenshots it, then
# hands a window off and back while it's open (the view should grow for the
# banner and shrink after, with no empty strip). Runs in the test VM.
param([string]$Dir = "C:\bcu")
$ErrorActionPreference = "Continue"
$bcu = Join-Path $Dir "bcu.exe"; $probe = Join-Path $Dir "bcu-probe.exe"; $ff = "C:\ffmpeg\bin\ffmpeg.exe"
$shots = Join-Path $Dir "shots"; New-Item -ItemType Directory $shots -Force | Out-Null; Remove-Item "$shots\*" -ErrorAction SilentlyContinue
$env:BCU_SESSION = "a"; $env:BCU_CLIENT = "claude-code"
function B { $o = & $bcu call @args 2>&1 | ForEach-Object { "$_" }; $script:last = ($o -join "`n"); Write-Output ">>> $($args -join ' ')"; $o | Select-Object -First 4 }
function Shot($name) { & $ff -loglevel error -y -f gdigrab -offset_x 0 -offset_y 0 -video_size 1920x1080 -i desktop -frames:v 1 (Join-Path $shots "$name.png"); Write-Output "shot: $name" }
function Viewer { & $probe windows BackgroundComputerUse | Where-Object { $_ -match "BCUViewer|BCUDim" } }
Get-Process BackgroundComputerUse, msedge -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
Start-Process (Join-Path $Dir "BackgroundComputerUse.exe") -WindowStyle Hidden
B status
B open_window app=msedge
$w = [regex]::Match($last, "Opened window (\d+)").Groups[1].Value
B get_window_state window_id=$w screenshot=false
$addr = [regex]::Match($last, '\[(\d+)\] Edit "Address and search bar').Groups[1].Value
B click window_id=$w element=$addr
B type_text window_id=$w "text=en.wikipedia.org/wiki/Hyper-V\n"
Start-Sleep -Seconds 2
$tr = (& $probe tray-rect).Trim() -split ' '
& $probe mouse ([int]$tr[0] + [int]$tr[2] / 2) ([int]$tr[1] + [int]$tr[3] / 2) left
Start-Sleep -Milliseconds 800
$pl = & $probe windows BackgroundComputerUse | Where-Object { $_ -match "BCUPopover" } | Select-Object -First 1
$m = [regex]::Match("$pl", "\[BCUPopover\] (\d+)x(\d+) at \((-?\d+),(-?\d+)\)")
Write-Output "popover: $pl"
& $probe mouse ([int]$m.Groups[3].Value + 230) ([int]$m.Groups[4].Value + 180) left
Start-Sleep -Milliseconds 1000
Viewer
Shot "1-expanded"
B handoff window_id=$w "reason=Sign in to continue"
Start-Sleep -Milliseconds 1000
Viewer
Shot "2-expanded-handoff"
B take_back window_id=$w
Start-Sleep -Milliseconds 1000
Viewer
Shot "3-expanded-back"
& $probe tap escape
Start-Sleep -Milliseconds 500
Write-Output "after escape:"; Viewer
B release_window window_id=$w
Get-Process BackgroundComputerUse -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Output "=== done"
