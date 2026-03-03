#!/bin/bash
set -e

loggedInUser=$(stat -f "%Su" /dev/console)

if [[ "$loggedInUser" == "loginwindow" || -z "$loggedInUser" ]]; then
  echo "HELIOS: No GUI user session found, skipping bootstrap"
  exit 0
fi

loggedInUID=$(id -u "$loggedInUser")

echo "HELIOS: Enabling and bootstrapping agent for $loggedInUser (uid $loggedInUID)"
launchctl enable gui/"$loggedInUID"/io.github.xishie.helios.timer || true
launchctl bootout gui/"$loggedInUID" /Library/LaunchAgents/io.github.xishie.helios.timer.plist 2>/dev/null || true
launchctl enable gui/"$loggedInUID"/io.github.xishie.helios.timer || true
launchctl bootstrap gui/"$loggedInUID" /Library/LaunchAgents/io.github.xishie.helios.timer.plist
launchctl kickstart -k gui/"$loggedInUID"/io.github.xishie.helios.timer
