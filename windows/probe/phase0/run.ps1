# Phase 0: what does Windows allow for background computer use?
# Runs inside the test VM, in the signed-in user's desktop session, not elevated.
# Edge plays the agent's window (Chromium, like the user's Helium); Notepad plays
# the user's window, in front, being typed into.
param(
  [string]$Dir = "C:\bcu",
  [string]$Only = ""   # run one section: uia, post, frames, swap, shared, launch, vmon, restore, textarea, calc
)
$Probe = Join-Path $Dir "bcu-probe.exe"
$Page = Join-Path $Dir "test.html"
$App = Join-Path $Dir "BackgroundComputerUse.exe"
$ErrorActionPreference = "Continue"

function P { Write-Output "`n>>> probe $($args -join ' ')"; & $Probe @args 2>&1 | ForEach-Object { "$_" } }
function Find($f) { $o = & $Probe find $f 2>$null; if ($o) { "$o".Trim() } else { $null } }
function Section($name) { return ($Only -eq "" -or $Only -eq $name) }
function UserFront { & $Probe fg $np | Out-Null; Start-Sleep -Milliseconds 300 }

Write-Output "=== Phase 0 probe, $(Get-Date -Format s), $([Environment]::OSVersion.VersionString)"
P monitors

# The agent's window: Edge on the test page.
Get-Process msedge, notepad, CalculatorApp -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Process msedge -ArgumentList "--new-window", "file:///$($Page -replace '\\','/')"
Start-Sleep -Seconds 5
$edge = Find "BCU probe page"
# The user's window: Notepad, in front.
Start-Process notepad
Start-Sleep -Seconds 3
$np = Find "Notepad"
Write-Output "edge=$edge notepad=$np"
if (-not $edge -or -not $np) { P windows; throw "test windows not found" }
P move $edge 40 40 1200 900
P move $np 700 120 900 600
P type-into $np "user is typing here. " 15

# Foreground changes for the whole run.
$fgLog = Join-Path $Dir "fg.log"
$fgProc = Start-Process $Probe -ArgumentList "fg-watch", "900" -RedirectStandardOutput $fgLog -PassThru -WindowStyle Hidden
P windows

if (Section "uia") {
  Write-Output "`n##### UI Automation without focus"
  P uia-dump $edge 60
  P uia-invoke $edge "Increment"
  P uia-grep $edge "count "
  P uia-setvalue $edge "Probe input" "set by uia"
  P uia-value $edge "Probe input"
  P uia-focus $edge "Probe textarea"
  UserFront
}

if (Section "post") {
  Write-Output "`n##### Posted keys and clicks to a background Chromium window"
  P post-click-name $edge "Increment"
  P uia-grep $edge "count "
  P post-chars $edge "posted chars"
  P uia-value $edge "Probe textarea"
  P post-key $edge "a" "ctrl"
  P post-key $edge "a" "ctrl" --state
  P post-key $edge "return"
  P post-key $edge "x"
  P uia-grep $edge "keydown"
  P post-key $edge "l" "ctrl" --state
  Start-Sleep -Milliseconds 500
  P uia-grep $edge "address"
  P post-key $edge "escape"
  P uia-grep $edge "mousedown"
  Write-Output "`n--- Notepad (classic Win32 path) ---"
  P post-chars $np "[posted into notepad]"
  P uia-grep $np "posted into notepad"
}

if (Section "frames") {
  Write-Output "`n##### Does a hidden window keep drawing?"
  Write-Output "-- visible, Notepad partly over it"
  P frames $edge 4 250
  Write-Output "-- fully covered by Notepad"
  P move $np 0 0 1920 1040
  P frames $edge 4 250
  P move $np 700 120 900 600
  Write-Output "-- moved off every monitor"
  P move $edge -3000 40
  P frames $edge 4 250
  P uia-invoke $edge "Increment"
  P uia-grep $edge "count "
  P move $edge 40 40
  Write-Output "-- minimized (expected to stop)"
  P capture $edge (Join-Path $Dir "edge-visible.png")
}

if (Section "swap") {
  Write-Output "`n##### Foreground swap: agent window forward for a moment, then back"
  UserFront
  P swap $edge 20 --film
  P swap $edge 0 --film
  P uia-grep $edge "window"
}

if (Section "shared") {
  Write-Output "`n##### The user types while the agent posts keys elsewhere"
  UserFront
  $typing = "The quick brown fox jumps over the lazy dog 0123456789. "
  $typer = Start-Process $Probe -ArgumentList "type-into", $np, "`"$typing$typing`"", "12" -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 300
  1..3 | ForEach-Object { P post-chars $edge "agent$_ "; P uia-setvalue $edge "Probe input" "agent set $_" }
  $typer.WaitForExit()
  P uia-grep $np "quick brown"
  P uia-value $edge "Probe textarea"
}

if (Section "launch") {
  Write-Output "`n##### Opening a new window of a running app, moved away as soon as it shows"
  UserFront
  P launch msedge.exe --new-window about:blank --to "-3000,40"
  P launch notepad.exe --to "-3000,40"
}

if (Section "vmon") {
  Write-Output "`n##### The agent's window on a virtual monitor"
  $lines = & $Probe monitors
  $lines | ForEach-Object { "  $_" }
  $prim = $lines | Where-Object { $_ -match "primary" } | Select-Object -First 1
  $virt = $lines | Where-Object { $_ -notmatch "primary" } | Select-Object -First 1
  if (-not $virt) {
    Write-Output "no second monitor (is the Virtual Display Driver installed?)"
  } else {
    $pm = [regex]::Match($prim, "(\d+)x(\d+) at \((-?\d+),(-?\d+)\)")
    $dev = ($virt -split " ")[0]
    $pw = [int]$pm.Groups[1].Value; $ph = [int]$pm.Groups[2].Value
    Write-Output "-- touching the primary at its bottom-right corner only"
    P monitor-pos $dev $pw $ph
    Write-Output "-- far from the primary (does Windows allow a gap?)"
    P monitor-pos $dev ($pw + 5000) ($ph + 5000)
    Write-Output "-- right of the primary (the default)"
    P monitor-pos $dev $pw 0
    $vm = [regex]::Match((& $Probe monitors | Where-Object { $_ -notmatch "primary" } | Select-Object -First 1), "at \((-?\d+),(-?\d+)\)")
    $vx = [int]$vm.Groups[1].Value; $vy = [int]$vm.Groups[2].Value
    P move $edge ($vx + 40) ($vy + 40) 1200 900
    UserFront
    P frames $edge 4 250
    P uia-invoke $edge "Increment"
    P post-click-name $edge "Increment"
    P uia-grep $edge "count "
    P post-chars $edge "on the virtual monitor"
    P uia-value $edge "Probe textarea"
    P capture $edge (Join-Path $Dir "edge-vmon.png")
    P launch msedge.exe --new-window about:blank
    P windows
    P move $edge 40 40
  }
}

if (Section "restore") {
  Write-Output "`n##### The agent's window takes the foreground; how do we give it back?"
  Write-Output "whoami: $(whoami /groups | Select-String 'Mandatory Label')"
  foreach ($m in @("plain", "attach", "switch", "uiafocus", "hide", "alt", "all")) {
    P steal-restore $edge $np $m
  }
}

if (Section "textarea") {
  Write-Output "`n##### Posted click into a text field, then posted typing"
  P post-click-name $edge "Probe textarea"
  P post-chars $edge "posted into the textarea"
  P uia-value $edge "Probe textarea"
  P post-key $edge "a" "ctrl" --state
  P post-chars $edge "replaced"
  P uia-value $edge "Probe textarea"
  P post-key $edge "home"
  P post-key $edge "right" "shift" --state
  P post-key $edge "delete"
  P uia-value $edge "Probe textarea"
  P post-click-name $edge "Probe input"
  P post-chars $edge "line one\nline two"
  P uia-value $edge "Probe input"
  P uia-grep $edge "keydown Enter"
}

if (Section "calc") {
  Write-Output "`n##### A UWP app (Calculator)"
  Start-Process calc
  Start-Sleep -Seconds 4
  $calc = Find "Calculator"
  Write-Output "calc=$calc"
  if ($calc) {
    UserFront
    P uia-dump $calc 80
    P post-click-name $calc "One"
    P uia-grep $calc "Display is"
    P post-chars $calc "23"
    P uia-grep $calc "Display is"
    P steal-restore $calc $np all "Seven"
    P uia-grep $calc "Display is"
    P frames $calc 3 250
  }
}

Start-Sleep -Milliseconds 500
Stop-Process -Id $fgProc.Id -Force -ErrorAction SilentlyContinue
Write-Output "`n##### Foreground log"
Get-Content $fgLog
Write-Output "`n##### App snapshot of the Edge window"
& $App --snapshot $edge 80 2>&1 | ForEach-Object { "$_" }
Write-Output "=== done"
