# A screen recording of the app at work: the user's screen and the agent's
# monitor side by side, with a caption for each step and the tray icon enlarged.
# A simulated user types into Notepad the whole time; the agent's steps are
# scripted bcu calls. Runs inside the test VM, in the signed-in user's session.
param([string]$Dir = "C:\bcu", [string]$Out = "C:\bcu\demo.mp4")
$ErrorActionPreference = "Continue"
$bcu = Join-Path $Dir "bcu.exe"
$probe = Join-Path $Dir "bcu-probe.exe"
$page = "file:///" + ((Join-Path $Dir "test.html") -replace '\\', '/')

# ---------- ffmpeg ----------
$ff = "C:\ffmpeg\bin\ffmpeg.exe"
if (-not (Test-Path $ff)) {
  Write-Output "downloading ffmpeg"
  $zip = "$env:TEMP\ffmpeg.zip"
  Invoke-WebRequest "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip" -OutFile $zip -UseBasicParsing
  Remove-Item "$env:TEMP\ffmpeg-x" -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive $zip -DestinationPath "$env:TEMP\ffmpeg-x" -Force
  $inner = Get-ChildItem "$env:TEMP\ffmpeg-x" -Directory | Select-Object -First 1
  New-Item -ItemType Directory C:\ffmpeg -Force | Out-Null
  Copy-Item "$($inner.FullName)\bin" C:\ffmpeg\ -Recurse -Force
}

# ---------- captions (read by ffmpeg every frame) ----------
$capAgent = Join-Path $Dir "cap-agent.txt"
$capYou = Join-Path $Dir "cap-you.txt"
function SetCap($file, $text) {
  $tmp = "$file.tmp"
  [IO.File]::WriteAllText($tmp, $text)
  for ($i = 0; $i -lt 20; $i++) { try { Move-Item $tmp $file -Force -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 15 } }
}
function Agent($text) { SetCap $capAgent "Agent: $text"; Write-Output "`n### agent: $text" }
function You($text) { SetCap $capYou "You: $text"; Write-Output "### you: $text" }
function B { $o = & $bcu call @args 2>&1 | ForEach-Object { "$_" }; $script:last = ($o -join "`n"); Write-Output ">>> bcu call $($args -join ' ')"; ($o | Select-Object -First 12); }
function J($s) { $s -replace '"', '\"' }
function Elem($pattern) { $m = [regex]::Match($script:last, "\[(\d+)\] $pattern"); if ($m.Success) { $m.Groups[1].Value } else { Write-Output "!! no element matching $pattern"; $null } }
# After an action the app reports whether the agent's window took the foreground.
function GuardNote {
  $m = [regex]::Match($script:last, "Focus guard: (.*)")
  if ($m.Success) { You "keep typing (Edge grabbed focus; handed back in $([regex]::Match($m.Groups[1].Value, '[\d.]+ ms').Value))"; Start-Sleep -Milliseconds 2500; You "typing in Notepad" }
}
function Pause($ms = 1300) { Start-Sleep -Milliseconds $ms }

# ---------- clean start ----------
Get-Process BackgroundComputerUse, msedge, notepad, ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\TabState\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\WindowState\*" -Force -ErrorAction SilentlyContinue
SetCap $capAgent " "
SetCap $capYou " "

$app = Start-Process (Join-Path $Dir "BackgroundComputerUse.exe") -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
# Windows 11 tucks new tray icons into the overflow menu; show ours on the taskbar.
Get-ChildItem "HKCU:\Control Panel\NotifyIconSettings" -ErrorAction SilentlyContinue | ForEach-Object {
  if ((Get-ItemProperty $_.PSPath).ExecutablePath -like "*BackgroundComputerUse.exe") { Set-ItemProperty $_.PSPath IsPromoted 1 -Type DWord; Write-Output "tray icon promoted" }
}

$userFile = Join-Path $Dir "notes-$(Get-Date -Format HHmmss).txt"
Set-Content -Path $userFile -Value "" -NoNewline
Start-Process notepad -ArgumentList $userFile
Start-Sleep -Seconds 3
$np = (& $probe find (Split-Path $userFile -Leaf)).Trim()
& $probe move $np 120 90 1100 760 | Out-Null
& $probe fg $np | Out-Null

# ---------- where the screens are ----------
$mons = & $probe monitors
$mons
$prim = $mons | Where-Object { $_ -match "primary" } | Select-Object -First 1
$pm = [regex]::Match($prim, "(\d+)x(\d+) at \((-?\d+),(-?\d+)\)")
$pw = [int]$pm.Groups[1].Value; $ph = [int]$pm.Groups[2].Value
# The app puts its monitor at the primary's bottom-right corner.
$ax = $pw; $ay = $ph

# ---------- record ----------
$font = "C\\:/Windows/Fonts/segoeui.ttf"
$fontB = "C\\:/Windows/Fonts/segoeuib.ttf"
$ca = ($capAgent -replace '\\', '/') -replace ':', '\\:'
$cy = ($capYou -replace '\\', '/') -replace ':', '\\:'
$graph = @"
color=c=0x111214:s=2448x900:r=15[bg];
[0:v]split[u0][t0];
[u0]scale=1280:720:flags=lanczos[u];
[1:v]scale=1152:720:flags=lanczos[a];
[t0]crop=420:48:$($pw-420):$($ph-48),scale=630:72:flags=neighbor[t];
[bg][u]overlay=0:62:shortest=1[v1];
[v1][a]overlay=1296:62[v2];
[v2][t]overlay=2448-630-24:900-72-34[v3];
[v3]drawtext=fontfile=$($fontB):text='Your screen':fontcolor=white:fontsize=30:x=20:y=16,
drawtext=fontfile=$($fontB):text='Agent screen (you never see this)':fontcolor=white:fontsize=30:x=1316:y=16,
drawtext=fontfile=$($font):textfile=$($ca):reload=1:fontcolor=white:fontsize=32:x=20:y=62+720+26,
drawtext=fontfile=$($font):textfile=$($cy):reload=1:fontcolor=0xb8bcc4:fontsize=28:x=20:y=62+720+72,
drawtext=fontfile=$($font):text='Tray':fontcolor=0x8a8f98:fontsize=22:x=2448-630-24:y=900-72-34-30[out]
"@
$graphFile = Join-Path $Dir "demo-graph.txt"
[IO.File]::WriteAllText($graphFile, $graph)
$raw = Join-Path $Dir "demo-raw.mkv"
Remove-Item $raw, $Out -ErrorAction SilentlyContinue
$psi = New-Object System.Diagnostics.ProcessStartInfo $ff
$psi.Arguments = "-y -hide_banner -loglevel warning -f gdigrab -framerate 15 -draw_mouse 1 -offset_x 0 -offset_y 0 -video_size ${pw}x${ph} -i desktop " +
  "-f gdigrab -framerate 15 -draw_mouse 0 -offset_x $ax -offset_y $ay -video_size 1600x1000 -i desktop " +
  "-/filter_complex `"$graphFile`" -map `"[out]`" -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p `"$raw`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$rec = [System.Diagnostics.Process]::Start($psi)
$recErr = $rec.StandardError.ReadToEndAsync()
Start-Sleep -Seconds 2
if ($rec.HasExited) { Write-Output "ffmpeg exited early:"; $recErr.Result; exit 1 }

# ---------- the user keeps working ----------
You "typing in Notepad"
$typing = "Notes for Thursday. Ask Sam about the budget review, then book the room for the offsite. " +
  "Remember to send the slides before lunch, and check the flight times for next week. "
$typer = Start-Process $probe -ArgumentList "type-into", $np, "`"$typing$typing$typing`"", "55" -PassThru -WindowStyle Hidden
Pause 2500

# ---------- the agent ----------
Agent "status (which browser is the default?)"
B status; Pause
Agent "open_window msedge (a new window on its own screen)"
B open_window app=msedge
$w = [regex]::Match($last, "Opened window (\d+)").Groups[1].Value
Pause 2500
Agent "get_window_state (reads the page's elements)"
B get_window_state window_id=$w screenshot=false; Pause
$addr = Elem 'Edit "Address and search bar'
Agent "click the address bar, type a URL"
B click window_id=$w element=$addr
B type_text window_id=$w "text=en.wikipedia.org/wiki/Hyper-V\n"; GuardNote
Pause 3000
Agent "get_window_state"
B get_window_state window_id=$w screenshot=false; Pause
Agent "scroll"
B scroll window_id=$w dy=5; Pause 1500
B scroll window_id=$w dy=5; Pause 1500
Agent "press_key ctrl+l, type a new URL"
B press_key window_id=$w key=l (J 'modifiers=["ctrl"]')
B type_text window_id=$w "text=$page\n"; GuardNote
Pause 2500
Agent "get_window_state"
B get_window_state window_id=$w screenshot=false
$inc = Elem 'Button "Increment"'
$input = Elem 'Edit "Probe input"'
$area = Elem 'Edit "Probe textarea"'
Pause
Agent "click Increment, three times"
B click window_id=$w element=$inc; Pause 500
B click window_id=$w element=$inc; Pause 500
B click window_id=$w element=$inc; Pause
Agent "type_text into a field"
B type_text window_id=$w element=$input "text=typed by the agent"; GuardNote; Pause
Agent "set_value through UI Automation"
B set_value window_id=$w element=$area "value=set through UI Automation, in the background"; GuardNote; Pause
Agent "batch: click, wait, press ctrl+a"
B batch window_id=$w (J ('actions=[{"tool":"click","element":' + $inc + '},{"tool":"wait","ms":300},{"tool":"click","element":' + $input + '},{"tool":"press_key","key":"a","modifiers":["ctrl"]}]')); Pause
Agent "screenshot"
B screenshot window_id=$w; Pause
Agent "guard_report"
B guard_report; Pause 1500

if (-not $typer.HasExited) { $typer.WaitForExit(30000) | Out-Null }
You "done typing"
Pause

# ---------- the tray ----------
$tr = (& $probe tray-rect 2>&1 | Out-String).Trim()
Write-Output "tray rect: $tr"
$tm = [regex]::Match($tr, "^(-?\d+) (-?\d+) (\d+) (\d+)$")
if ($tm.Success) {
  $tx = [int]$tm.Groups[1].Value + [int]$tm.Groups[3].Value / 2
  $ty = [int]$tm.Groups[2].Value + [int]$tm.Groups[4].Value / 2
  You "open the tray menu, pick Pause agents"
  & $probe mouse $tx $ty right; Pause 1800
  & $probe tap down; Pause 500
  & $probe tap return; Pause 1200
  Agent "click (refused while paused)"
  B click window_id=$w element=$inc; Pause 2500
  You "Resume agents"
  & $probe mouse $tx $ty right; Pause 1500
  & $probe tap down; Pause 400
  & $probe tap return; Pause 1000
  Agent "click"
  B click window_id=$w element=$inc; Pause 2000
  You "Stop agents (closes the agent's windows)"
  & $probe mouse $tx $ty right; Pause 1500
  & $probe tap down; Pause 300
  & $probe tap down; Pause 400
  & $probe tap return; Pause 2500
  & $probe mouse 700 600
} else {
  Agent "release_window"
  B release_window window_id=$w; Pause 2000
}
SetCap $capAgent " "
You "Notepad has only what you typed"
Pause 3000

# ---------- stop recording, compress ----------
$rec.StandardInput.Write("q"); $rec.StandardInput.Flush()
$rec.WaitForExit(30000) | Out-Null
if (-not $rec.HasExited) { $rec.Kill() }
Write-Output "ffmpeg log:"; $recErr.Result | Select-Object -Last 20
& $ff -y -hide_banner -loglevel warning -i $raw -c:v libx264 -preset slow -crf 25 -pix_fmt yuv420p -movflags +faststart $Out
Get-Item $Out | ForEach-Object { "video: $($_.FullName) $([math]::Round($_.Length / 1MB, 1)) MB" }

Write-Output "`n--- Notepad text:"
& $probe get-text $np
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Write-Output "=== done"
