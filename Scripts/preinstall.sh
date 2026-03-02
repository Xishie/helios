#!/bin/bash

loggedInUser=$(stat -f "%Su" /dev/console)
loggedInUID=$(id -u "$loggedInUser")

echo "HELIOS: Unloading existing agent (if present)"
launchctl bootout gui/"$loggedInUID" /Library/LaunchAgents/io.github.xishie.helios.timer.plist 2>/dev/null

exit 0