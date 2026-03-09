#!/bin/bash
# This script should not be part of the pkg. either run it manually or include it in the munki pkginfo.
# Fully removes helios: unloads agents, deletes plists, clears logs/cache for all users.

AGENTS=(
  "io.github.xishie.helios.timer"
  "io.github.xishie.helios.ConnectionCompleted"
  "io.github.xishie.helios.gotNewCredential"
  "io.github.xishie.helios.InternalNetworkAvailable"
)

PLIST_DIR="/Library/LaunchAgents"
HELIOS_DIR="/Library/helios"

get_console_user() {
  local user
  user=$(stat -f "%Su" /dev/console 2>/dev/null)
  if [[ -z "$user" || "$user" == "loginwindow" || "$user" == "_mbsetupuser" ]]; then
    return 1
  fi
  echo "$user"
}

unload_agents_for_uid() {
  local uid="$1"
  for label in "${AGENTS[@]}"; do
    echo "HELIOS: Unloading $label from gui/$uid"
    launchctl bootout "gui/${uid}" "${PLIST_DIR}/${label}.plist" 2>/dev/null || true
    launchctl disable "gui/${uid}/${label}" 2>/dev/null || true
  done
}

clean_user_artifacts() {
  local home="$1"
  if [[ -n "$home" && -d "$home" ]]; then
    echo "HELIOS: Removing logs/cache in $home"
    rm -rf "$home/Library/Logs/helios" 2>/dev/null || true
    rm -rf "$home/Library/Caches/helios" 2>/dev/null || true
  fi
}

echo "HELIOS: Postuninstall starting"

# Unload agents from the active GUI session if one exists
if consoleUser=$(get_console_user); then
  uid=$(id -u "$consoleUser" 2>/dev/null)
  [[ -n "$uid" ]] && unload_agents_for_uid "$uid"
else
  echo "HELIOS: No active GUI user session, skipping agent bootout"
fi

# Clean per-user artifacts for every user on the system
while IFS= read -r userHome; do
  [[ -d "$userHome" ]] && clean_user_artifacts "$userHome"
done < <(dscl . -list /Users NFSHomeDirectory 2>/dev/null | awk '$2 ~ /^\/Users\// {print $2}')

# Remove temp stdout/stderr files
echo "HELIOS: Removing temp files"
for label in "${AGENTS[@]}"; do
  rm -f "/tmp/${label}.out" "/tmp/${label}.err" 2>/dev/null || true
done

# Remove LaunchAgent plists
echo "HELIOS: Removing LaunchAgent plists"
for label in "${AGENTS[@]}"; do
  rm -f "${PLIST_DIR}/${label}.plist" 2>/dev/null || true
done

# Remove the helios application support directory
echo "HELIOS: Removing $HELIOS_DIR"
rm -rf "$HELIOS_DIR" 2>/dev/null || true

echo "HELIOS: Forgetting PKG"
pkgutil --forget io.github.xishie.helios

echo "HELIOS: Postuninstall complete"
exit 0