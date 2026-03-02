#!/bin/bash

loggedInUser=$(stat -f "%Su" /dev/console)

echo "HELIOS: Cleaning up logs and cache"
rm -rf "/Users/$loggedInUser/Library/Logs/helios"
rm -rf "/Users/$loggedInUser/Library/Caches/helios"

exit 0