#!/bin/bash
set -u

PLIST="/Library/LaunchAgents/io.github.xishie.helios.timer.plist"
LABEL="io.github.xishie.helios.timer"
SCRIPT_DIR="/Library/Application Support/helios"

consoleUser="$(stat -f "%Su" /dev/console 2>/dev/null || true)"

echo "HELIOS: postuninstall starting, consoleUser=$consoleUser"

# Try to unload from the active GUI session if there is one
if [[ -n "$consoleUser" && "$consoleUser" != "loginwindow" ]]; then
  if uid="$(id -u "$consoleUser" 2>/dev/null)"; then
    echo "HELIOS: Attempting to unload LaunchAgent from gui/$uid"
    launchctl bootout "gui/$uid" "$PLIST" 2>/dev/null || true
    launchctl disable "gui/$uid/$LABEL" 2>/dev/null || true

    # Remove per-user artifacts using the real home directory
    homeDir="$(dscl . -read "/Users/$consoleUser" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$homeDir" && -d "$homeDir" ]]; then
      echo "HELIOS: Removing logs/cache for $consoleUser in $homeDir"
      rm -rf "$homeDir/Library/Logs/helios" 2>/dev/null || true
      rm -rf "$homeDir/Library/Caches/helios" 2>/dev/null || true
    fi
  fi
else
  echo "HELIOS: No active GUI user session found, skipping gui bootout"
fi

# Remove temp stdout/stderr files (if they exist)
echo "HELIOS: Removing temp stdout/stderr files"
rm -f /tmp/io.github.xishie.helios.timer.out /tmp/io.github.xishie.helios.timer.err 2>/dev/null || true

# Optional cleanup of installed files (uncomment if you want full removal)
echo "HELIOS: Removing installed files"
rm -f "$PLIST" 2>/dev/null || true
rm -rf "$SCRIPT_DIR" 2>/dev/null || true

echo "HELIOS: postuninstall complete"
exit 0