#!/bin/bash

loggedInUser=$(stat -f "%Su" /dev/console)

if [[ "$loggedInUser" == "loginwindow" || -z "$loggedInUser" ]]; then
  echo "HELIOS: No GUI user session found, skipping bootout"
  exit 0
fi

loggedInUID=$(id -u "$loggedInUser")

echo "HELIOS: Unloading existing agent (if present) for uid $loggedInUID"
launchctl bootout gui/"$loggedInUID" /Library/LaunchAgents/io.github.xishie.helios.timer.plist 2>/dev/null || true