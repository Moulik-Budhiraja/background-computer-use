# Two agents at once, and the tray's live preview: agent "a" (Claude Code)
# and agent "b" (Codex) each open Edge on their own monitor and work, while
# the user types in Notepad, then uses the tray popover (pause, handoff,
# expand, stop). Saves screenshots to C:\bcu\shots and records the user's
# screen to C:\bcu\multi.mp4. Runs inside the test VM, in the user's session.
param([string]$Dir = "C:\bcu")
$ErrorActionPreference = "Continue"
$bcu = Join-Path $Dir "bcu.exe"
$probe = Join-Path $Dir "bcu-probe.exe"
$ff = "C:\ffmpeg\bin\ffmpeg.exe"
$page = "file:///" + ((Join-Path $Dir "test.html") -replace '\\', '/')
$shots = Join-Path $Dir "shots"
New-Item -ItemType Directory $shots -Force | Out-Null
Remove-Item "$shots\*" -ErrorAction SilentlyContinue

function J($s) { $s -replace '"', '\"' }
function As($who) { $env:BCU_SESSION = $who; $env:BCU_CLIENT = @{ a = "claude-code"; b = "codex" }[$who] }
function B($who) {
  As $who
  $rest = $args
  $t = [Diagnostics.Stopwatch]::StartNew()
  $o = & $bcu call @rest 2>&1 | ForEach-Object { "$_" }
  $script:last = ($o -join "`n")
  Write-Output ">>> [$who] bcu call $($rest -join ' ')   ($($t.ElapsedMilliseconds) ms)"
  $o | Select-Object -First 8
}
# Run a call in the background (a separate bcu process), for parallel agents.
function Bg($who) {
  As $who
  $out = Join-Path $Dir "bg-$who-$(Get-Random).txt"
  $p = Start-Process $bcu -ArgumentList (@("call") + $args) -PassThru -WindowStyle Hidden -RedirectStandardOutput $out
  $p | Add-Member -NotePropertyName Out -NotePropertyValue $out -PassThru
}
function Elem($pattern) { $m = [regex]::Match($script:last, "\[(\d+)\] $pattern"); if ($m.Success) { $m.Groups[1].Value } else { Write-Output "!! no element matching $pattern"; $null } }
function Shot($name) { & $ff -loglevel error -y -f gdigrab -offset_x 0 -offset_y 0 -video_size 1920x1080 -i desktop -frames:v 1 (Join-Path $shots "$name.png"); Write-Output "shot: $name" }
function Click($x, $y) { & $probe mouse $x $y left | Out-Null }
# The popover's place: x, y, width (device pixels; logical at 100%).
function PopRect {
  $line = & $probe windows BackgroundComputerUse | Where-Object { $_ -match "\[BCUPopover\]" } | Select-Object -First 1
  $m = [regex]::Match("$line", "\[BCUPopover\] (\d+)x(\d+) at \((-?\d+),(-?\d+)\)")
  Write-Output "popover: $line"
  if ($m.Success) { $script:px = [int]$m.Groups[3].Value; $script:py = [int]$m.Groups[4].Value; $script:pw = [int]$m.Groups[1].Value; $script:right = $script:px + $script:pw }
  else { Write-Output "!! popover not found" }
}

# ---------- start ----------
Get-Process BackgroundComputerUse, msedge, notepad, ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\TabState\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\WindowState\*" -Force -ErrorAction SilentlyContinue
Write-Output "monitors before the app:"; & $probe monitors
$app = Start-Process (Join-Path $Dir "BackgroundComputerUse.exe") -PassThru -WindowStyle Hidden
# The app asks the driver for four monitors at start; that reloads them.
$t = [Diagnostics.Stopwatch]::StartNew()
B a status
Write-Output "first call answered after $($t.ElapsedMilliseconds) ms"
Write-Output "monitors after:"; & $probe monitors
Get-ChildItem "HKCU:\Control Panel\NotifyIconSettings" -ErrorAction SilentlyContinue | ForEach-Object {
  if ((Get-ItemProperty $_.PSPath).ExecutablePath -like "*BackgroundComputerUse.exe") { Set-ItemProperty $_.PSPath IsPromoted 1 -Type DWord }
}
Get-Content C:\VirtualDisplayDriver\vdd_settings.xml -ErrorAction SilentlyContinue | Select-String "<count>"

$userFile = Join-Path $Dir "notes-$(Get-Date -Format HHmmss).txt"
Set-Content -Path $userFile -Value "" -NoNewline
Start-Process notepad -ArgumentList $userFile
Start-Sleep -Seconds 3
$np = (& $probe find (Split-Path $userFile -Leaf)).Trim()
& $probe move $np 120 90 1000 700 | Out-Null
& $probe fg $np | Out-Null

# Record the user's screen, with the tray enlarged in a corner.
$graph = "[0:v]split[a][b];[b]crop=420:48:1500:1032,scale=630:72:flags=neighbor[t];[a][t]overlay=20:1080-48-72-20"
$psi = New-Object System.Diagnostics.ProcessStartInfo $ff
$psi.Arguments = "-y -hide_banner -loglevel warning -f gdigrab -framerate 15 -offset_x 0 -offset_y 0 -video_size 1920x1080 -i desktop -filter_complex `"$graph`" -c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p `"$Dir\multi-raw.mkv`""
$psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
$rec = [System.Diagnostics.Process]::Start($psi)
$recErr = $rec.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 1

# ---------- the user types; both agents open Edge at once ----------
$typing = "Notes for Thursday. Ask Sam about the budget review, then book the room for the offsite. "
$typer = Start-Process $probe -ArgumentList "type-into", $np, "`"$typing$typing`"", "45" -PassThru -WindowStyle Hidden
$pa = Bg a open_window app=msedge
$pb = Bg b open_window app=msedge
$pa.WaitForExit(30000) | Out-Null; $pb.WaitForExit(30000) | Out-Null
$oa = Get-Content $pa.Out -Raw; $ob = Get-Content $pb.Out -Raw
Write-Output "[a] $oa"; Write-Output "[b] $ob"
$wa = [regex]::Match($oa, "Opened window (\d+)").Groups[1].Value
$wb = [regex]::Match($ob, "Opened window (\d+)").Groups[1].Value
Write-Output "a=$wa b=$wb"
& $probe windows msedge

# Each on its own monitor?
B a status
B b status
B a list_windows
B b list_windows
B b get_window_state window_id=$wa screenshot=false

# Navigate both.
B a get_window_state window_id=$wa screenshot=false
$addr = Elem 'Edit "Address and search bar'
B a click window_id=$wa element=$addr
B a type_text window_id=$wa "text=en.wikipedia.org/wiki/Hyper-V\n"
B b get_window_state window_id=$wb screenshot=false
$addr = Elem 'Edit "Address and search bar'
B b click window_id=$wb element=$addr
B b type_text window_id=$wb "text=$page\n"
Start-Sleep -Seconds 2
B b get_window_state window_id=$wb screenshot=false
$inc = Elem 'Button "Increment"'
$input = Elem 'Edit "Probe input"'

# Parallel: a long call in a doesn't hold up b.
$long = Bg a batch window_id=$wa (J 'actions=[{"tool":"wait","ms":3000},{"tool":"scroll","dy":3}]') state=false
Start-Sleep -Milliseconds 300
B b click window_id=$wb element=$inc
$long.WaitForExit(15000) | Out-Null
Write-Output "[a, long] $(Get-Content $long.Out -Raw)"

$typer.WaitForExit(30000) | Out-Null
Write-Output "--- Notepad:"; & $probe get-text $np
Shot "01-working-tray"

# ---------- the popover ----------
$tr = (& $probe tray-rect 2>&1 | Out-String).Trim()
Write-Output "tray rect: $tr"
$tm = [regex]::Match($tr, "^(-?\d+) (-?\d+) (\d+) (\d+)$")
$tx = [int]$tm.Groups[1].Value + [int]$tm.Groups[3].Value / 2
$ty = [int]$tm.Groups[2].Value + [int]$tm.Groups[4].Value / 2
Click $tx $ty
Start-Sleep -Milliseconds 800
& $probe windows BackgroundComputerUse
# Both agents keep working while the popover is open.
for ($i = 0; $i -lt 4; $i++) {
  $sa = Bg a scroll window_id=$wa dy=4
  B b click window_id=$wb element=$inc
  Start-Sleep -Milliseconds 700
  if ($i -eq 1) { Shot "02-popover-two-agents" }
}
B b type_text window_id=$wb element=$input "text=typed by codex"
Start-Sleep -Milliseconds 600
Shot "03-popover-cursor"

PopRect

# Pause all from the header.
Click ($right - 87) ($py + 24)
Start-Sleep -Milliseconds 600
B a scroll window_id=$wa dy=2
Shot "04-paused"
# Resume all.
Click ($right - 87) ($py + 24)
Start-Sleep -Milliseconds 600

# Handoff from b: the banner shows under b's tile.
B b handoff window_id=$wb "reason=Sign in to your bank to continue"
Start-Sleep -Milliseconds 800
Shot "05-handoff"
# Done (the check button on b's banner): tile b is the second one. The
# popover grew for the banner, so find it again.
PopRect
$doneX = $px + 10 + 320 + 10 + 320 - 16
$doneY = $py + 10 + 28 + 10 + 200 + 8 + 14
Click $doneX $doneY
Start-Sleep -Milliseconds 800
B b status
Shot "06-handed-back"

# Expand a's tile.
PopRect
Click ($px + 10 + 160) ($py + 48 + 100)
Start-Sleep -Milliseconds 800
& $probe windows BackgroundComputerUse
B a scroll window_id=$wa dy=6
B a scroll window_id=$wa dy=-3
Start-Sleep -Milliseconds 500
Shot "07-expanded"
& $probe tap escape
Start-Sleep -Milliseconds 500

# Stop from the popover.
Click $tx $ty
Start-Sleep -Milliseconds 800
PopRect
Click ($right - 59) ($py + 24)
Start-Sleep -Milliseconds 1500
Shot "08-stopped"
& $probe tap escape
& $probe windows msedge

# The icon after the agents go quiet.
Start-Sleep -Seconds 4
Shot "09-idle-tray"

$rec.StandardInput.Write("q"); $rec.StandardInput.Flush()
$rec.WaitForExit(30000) | Out-Null
Write-Output "ffmpeg: $($recErr.Result)"
& $ff -y -hide_banner -loglevel warning -i "$Dir\multi-raw.mkv" -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p -movflags +faststart "$Dir\multi.mp4"
Get-Item "$Dir\multi.mp4" | ForEach-Object { "video: $($_.Length) bytes" }
Get-ChildItem $shots | ForEach-Object { "  $($_.Name) $($_.Length)" }
Write-Output "--- Notepad at the end:"; & $probe get-text $np
Write-Output "--- guard:"; B a guard_report
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Write-Output "=== done"
