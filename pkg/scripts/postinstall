#!/bin/bash

# Define launch agents to load
LAUNCH_AGENTS=(
    "io.github.xishie.helios.timer.plist"
    "io.github.xishie.helios.ConnectionCompleted.plist"
    "io.github.xishie.helios.gotNewCredential.plist"
    "io.github.xishie.helios.InternalNetworkAvailable.plist"
)

AGENTS_DIR="/Library/LaunchAgents"
HELIOS_DIR="/Library/helios"

# Get the console user (the one sitting at the GUI)
CONSOLE_USER=$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null)

# If no user is logged in (loginwindow, root, or empty), exit cleanly
# This covers Munki bootstrap mode, DEP enrollment, etc.
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "loginwindow" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "_mbsetupuser" ]]; then
    echo "No GUI user logged in (console user: '${CONSOLE_USER:-none}'). Skipping agent loading."
    exit 0
fi

chmod 755 "$HELIOS_DIR"
chmod +x "$HELIOS_DIR/helios.sh"
xattr -cr "$HELIOS_DIR/sso_bundle.app" 2>/dev/null || true

CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null)

if [[ -z "$CONSOLE_UID" || "$CONSOLE_UID" -eq 0 ]]; then
    echo "Could not resolve UID for user '$CONSOLE_USER'. Skipping agent loading."
    exit 0
fi

echo "Console user: $CONSOLE_USER (UID: $CONSOLE_UID)"

for AGENT in "${LAUNCH_AGENTS[@]}"; do
    PLIST_PATH="${AGENTS_DIR}/${AGENT}"
    LABEL="${AGENT%.plist}"
    SERVICE_TARGET="gui/${CONSOLE_UID}/${LABEL}"

    echo "Processing: $LABEL"

    # Check the plist actually exists on disk
    if [[ ! -f "$PLIST_PATH" ]]; then
        echo "  WARNING: $PLIST_PATH not found. Skipping."
        continue
    fi

    # Check if the service is already loaded
    if /bin/launchctl print "$SERVICE_TARGET" &>/dev/null; then
        echo "  Already loaded. Skipping."
        continue
    fi

    # Re-enable the agent if it was disabled (e.g. by a previous uninstall)
    DISABLED_STATUS=$(/bin/launchctl print-disabled "gui/${CONSOLE_UID}" 2>/dev/null | /usr/bin/grep -F "$LABEL")
    if echo "$DISABLED_STATUS" | /usr/bin/grep -q "disabled"; then
        echo "  Disabled by override. Re-enabling..."
        /bin/launchctl enable "gui/${CONSOLE_UID}/${LABEL}"
    fi

    # Bootstrap (load) the agent into the user's GUI domain
    echo "  Loading into gui/${CONSOLE_UID}..."
    if /bin/launchctl bootstrap "gui/${CONSOLE_UID}" "$PLIST_PATH" 2>&1; then
        echo "  Loaded successfully."
    else
        echo "  WARNING: Failed to load $LABEL (exit $?)."
    fi
done

echo "Postinstall complete."
touch /Library/helios/imadeit.iexist
exit 0