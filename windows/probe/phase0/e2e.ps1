# End to end: the app (BackgroundComputerUse.exe) driven through bcu.exe the way
# an agent would, while a simulated user types into Notepad in front.
# Runs inside the test VM, in the signed-in user's session, not elevated.
param([string]$Dir = "C:\bcu")
$bcu = Join-Path $Dir "bcu.exe"
$probe = Join-Path $Dir "bcu-probe.exe"
$page = "file:///" + ((Join-Path $Dir "test.html") -replace '\\', '/')
$ErrorActionPreference = "Continue"

function B { Write-Output "`n>>> bcu call $($args -join ' ')"; $o = & $bcu call @args 2>&1 | ForEach-Object { "$_" }; $o; $script:last = ($o -join "`n") }
# Windows PowerShell drops the double quotes inside native arguments; escape them.
function J($s) { $s -replace '"', '\"' }
function Elem($pattern) { $m = [regex]::Match($script:last, "\[(\d+)\] $pattern"); if ($m.Success) { $m.Groups[1].Value } else { Write-Output "!! no element matching $pattern"; "0" } }

Get-Process BackgroundComputerUse, msedge, notepad -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
# Windows 11 Notepad reopens its last session's tabs; start it clean.
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\TabState\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\WindowState\*" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\bcu-*.png" -ErrorAction SilentlyContinue

# The app, as the user would run it.
$app = Start-Process (Join-Path $Dir "BackgroundComputerUse.exe") -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Dir "app.log") -RedirectStandardError (Join-Path $Dir "app.err")
Start-Sleep -Seconds 2

# The user's window: Notepad on a fresh file, in front.
$userFile = Join-Path $Dir "user-$(Get-Date -Format HHmmss).txt"
Set-Content -Path $userFile -Value "" -NoNewline
Start-Process notepad -ArgumentList $userFile
Start-Sleep -Seconds 3
$np = (& $probe find (Split-Path $userFile -Leaf)).Trim()
& $probe move $np 200 150 1000 700 | Out-Null
& $probe type-into $np "user: " 10
Write-Output "notepad=$np"
& $probe windows notepad
& $probe monitors

B status
B open_window app=msedge
$w = [regex]::Match($last, "Opened window (\d+)").Groups[1].Value
Write-Output "window=$w"
& $probe windows msedge

B get_window_state window_id=$w screenshot=false
$addr = Elem 'Edit "Address and search bar'
B click window_id=$w element=$addr
B type_text window_id=$w "text=$page\n"
B get_window_state window_id=$w screenshot=false
$inc = Elem 'Button "Increment"'
$input = Elem 'Edit "Probe input"'
$area = Elem 'Edit "Probe textarea"'

Write-Output "`n##### The agent works while the user types"
$typing = "The quick brown fox jumps over the lazy dog 0123456789. "
$typer = Start-Process $probe -ArgumentList "type-into", $np, "`"$typing$typing$typing`"", "8" -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 300
B click window_id=$w element=$inc
B click window_id=$w element=$inc
B type_text window_id=$w element=$input "text=typed by the agent"
B press_key window_id=$w key=a (J 'modifiers=["ctrl"]')
B type_text window_id=$w text=replaced
B set_value window_id=$w element=$area "value=set through UI Automation"
B type_text window_id=$w element=$area "text= and typed"
B scroll window_id=$w dy=3
$typer.WaitForExit()
Write-Output "typer exit code: $($typer.ExitCode)"
Start-Sleep -Milliseconds 300
Write-Output "`n--- what the user's Notepad has (should be 'user: ' + the sentence three times, nothing else)"
& $probe get-text $np

B get_window_state window_id=$w screenshot=false full=true
B batch window_id=$w (J ('actions=[{"tool":"click","element":' + $inc + '},{"tool":"wait","ms":200},{"tool":"press_key","key":"l","modifiers":["ctrl"]}]'))
B screenshot window_id=$w
B guard_report
B list_windows app=msedge
B release_window window_id=$w
Start-Sleep -Milliseconds 500
& $probe windows msedge
Get-ChildItem "$env:TEMP\bcu-*.png" | ForEach-Object { Copy-Item $_.FullName (Join-Path $Dir "e2e-shot.png") -Force; "screenshot: $($_.Length) bytes" }

Write-Output "`n##### A real MCP session over bcu mcp"
$req = @(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"e2e"}}}',
  '{"jsonrpc":"2.0","method":"notifications/initialized"}',
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}'
) -join "`n"
$req | & $bcu mcp | ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + " ...(" + $_.Length + " chars)" } else { $_ } }

Write-Output "`n##### bcu connect (Claude Code and Codex aren't installed in this VM)"
& $bcu connect

Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Write-Output "`n##### app log"
Get-Content (Join-Path $Dir "app.log"), (Join-Path $Dir "app.err") -ErrorAction SilentlyContinue
Write-Output "=== done"
