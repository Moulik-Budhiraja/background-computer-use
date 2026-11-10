#!/bin/zsh
# Repro for "Helium takes my focus": does an agent step in a browser leave
# the browser second in the cmd+Tab order (so the user's next cmd+Tab lands
# in it instead of the app they came from)?
#
# Stay in some app other than the browser while it runs. It opens one
# browser window on the agent display, loads example.com, clicks the page,
# then closes the window, printing the first three apps of the cmd+Tab
# order after each step. Passes when the second app never changes.
#
#   scripts/cmdtab-order-repro.sh [path/to/bcu] [browser]
set -u
BCU=${1:-"/Applications/Background Computer Use.app/Contents/MacOS/bcu"}
APP=${2:-Helium}
order() { lsappinfo visibleProcessList | grep -o '"[^"]*"' | head -3 | tr '\n' ' '; }
second() { lsappinfo visibleProcessList | grep -o '"[^"]*"' | sed -n 2p; }

front=$(lsappinfo visibleProcessList | grep -o '"[^"]*"' | head -1 | tr -d '"')
if [[ $front == "$APP" ]]; then echo "switch to an app other than $APP first"; exit 64; fi
start=$(second)
echo "before:        $(order)"
out=$("$BCU" call open_window "{\"app\":\"$APP\"}") || { echo "$out"; exit 1; }
id=$(echo "$out" | grep -o 'Opened window [0-9]*' | grep -o '[0-9]*$')
[[ -n $id ]] || { echo "$out"; exit 1; }
trap '"$BCU" call release_window "{\"window_id\":$id}" >/dev/null' EXIT
sleep 1; echo "open_window:   $(order)"
"$BCU" call navigate "{\"window_id\":$id,\"url\":\"https://example.com\"}" >/dev/null
sleep 1; echo "navigate:      $(order)"
"$BCU" call click "{\"window_id\":$id,\"x\":700,\"y\":200}" >/dev/null
sleep 1; echo "click:         $(order)"
end=$(second)
if [[ $start == $end ]]; then
  echo "PASS: $start is still second, so cmd+Tab goes back to it"
else
  echo "FAIL: $end is now second instead of $start; cmd+Tab would land in it"
  exit 1
fi
