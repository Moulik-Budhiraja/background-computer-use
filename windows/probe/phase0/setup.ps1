# One-time VM setup for the Phase 0 probe (run elevated, inside the test VM only).
# Skips Edge's first-run pages so a new Edge window opens straight to the test page.
$k = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
New-Item -Path $k -Force | Out-Null
Set-ItemProperty -Path $k -Name HideFirstRunExperience -Value 1 -Type DWord
Set-ItemProperty -Path $k -Name StartupBoostEnabled -Value 0 -Type DWord
Set-ItemProperty -Path $k -Name BackgroundModeEnabled -Value 0 -Type DWord
Set-ItemProperty -Path $k -Name PromotionalTabsEnabled -Value 0 -Type DWord
Write-Output "Edge first-run disabled"
