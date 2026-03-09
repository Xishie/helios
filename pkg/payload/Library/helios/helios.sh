#!/usr/bin/env bash
set -u

preferences="/Library/Managed Preferences/io.github.xishie.helios.plist"
loggedInUser=$(stat -f "%Su" /dev/console)

appname="helios"
logdir="/Users/$loggedInUser/Library/Logs/$appname"
log="$logdir/$appname.log"

log_entry() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local service="launchd"
    local level="$1"
    local pid="$$"
    local component="$appname"
    local message="$2"
    echo "$timestamp | $service | $level | $pid | $component | $message"
}

startLog() {
    if [[ ! -d "$logdir" ]]; then
        mkdir -p "$logdir"
        log_entry "I" "Creating [$logdir] to store logs"
    fi
    exec > >(tee -a "$log") 2>&1
}

rotateLog() {
    if [[ -f "$log" ]]; then
        local filesize
        filesize=$(stat -f%z "$log")
        if [[ $filesize -gt 1048576 ]]; then
            log_entry "I" "Log file exceeds 1MB, deleting"
            rm -f "$log"
            touch "$log"
        fi
    fi
}

check_preferences() {
    if [[ ! -f "$preferences" ]]; then
        log_entry "W" "Configuration profile preferences is not present under $preferences"
        exit 0
    fi
}

# ---------------------------
# Plist parsing helpers
# ---------------------------

plist_print() {
    local keypath="$1"
    /usr/libexec/PlistBuddy -c "Print $keypath" "$preferences" 2>/dev/null
}

plist_get_string() {
    local keypath="$1"
    plist_print "$keypath" | head -n1
}

# Reads environment from preferences.plist
load_env_from_preferences() {
    realm=$(plist_get_string ":realm")
    domain=$(plist_get_string ":domain")
    domainPath=$(plist_get_string ":domainPath")

    if [[ -z "$realm" ]]; then
        log_entry "W" "No realm found in preferences plist (key :realm), exiting"
        exit 0
    fi

    if [[ -z "$domain" ]]; then
        log_entry "W" "No domain found in preferences plist (key :domain), exiting"
        exit 0
    fi

    if [[ -z "$domainPath" ]]; then
        log_entry "W" "No domainPath found in preferences plist (key :domainPath), exiting"
        exit 0
    fi

    log_entry "I" "Loaded environment from preferences, realm=[$realm], domain=[$domain]"
}

# ---------------------------
# KSSOE state (depends on realm)
# ---------------------------

load_kssoe_state() {
    kssoeState=$(app-sso -i "$realm" -j | jq -r '.upn // empty')
    netState=$(app-sso -i "$realm" -j | jq -r '.networkAvailable // empty')
    adUser=$(echo "$kssoeState" | cut -d'@' -f1)
}

check_net() {
    if [[ -z "$netState" ]]; then
        log_entry "W" "Corporate network is not available for the Kerberos Single Sign On Extension, exiting"
        exit 0
    fi
}

check_auth() {
    if [[ -z "$kssoeState" ]]; then
        log_entry "W" "User is not authenticated through the Kerberos Single Sign On Extension, exiting"
        exit 0
    fi
}

# ---------------------------
# Kerberos + LDAP group lookup
# ---------------------------

get_groups() {
    local kCache
    local output
    local rc

    ad_groups=""

    # Cache AD groups locally to reduce LDAP/DC load
    local cache_dir cache_file cache_ttl now mtime age
    cache_dir="/Users/$loggedInUser/Library/Caches/$appname"
    cache_file="$cache_dir/ad_groups.txt"
    cache_ttl=14400   # 14400 for 4 hours, 900 for 15 minutes or 3600 for 1 hour
    now=$(date +%s)

    if [[ -f "$cache_file" ]]; then
        mtime=$(stat -f %m "$cache_file")
        age=$(( now - mtime ))

        if [[ $age -lt $cache_ttl ]]; then
            ad_groups=$(cat "$cache_file")

            if [[ -n "$ad_groups" ]]; then
                log_entry "I" "Using cached AD groups (age ${age}s)"
                return 0
            fi
        fi
    fi

    # Pick the first non-expired cache matching the realm
    kCache=$(klist -l | awk -v r="$realm" 'NR>1 && $0 !~ /Expired/ && $0 ~ ("@" r) {print $2; exit}')

    if [[ -z "$kCache" ]]; then
        log_entry "E" "No valid Kerberos cache found for realm [$realm]"
        exit 0
    else
        log_entry "I" "Using Kerberos cache [$kCache]"
    fi

    output=$(KRB5CCNAME="$kCache" ldapsearch -LLL -Y GSSAPI -H "ldap://$domain" -b "$domainPath" "(sAMAccountName=$adUser)" memberOf 2>&1)
    rc=$?

    if [[ $rc -ne 0 ]]; then
        log_entry "E" "ldapsearch failed for [$adUser], rc=$rc"
        log_entry "E" "ldapsearch output: $output"
        exit 0
    fi

    ad_groups=$(printf '%s\n' "$output" | awk -F'[=,]' '/^memberOf:[[:space:]]/ {print $2}')

    if [[ -z "$ad_groups" ]]; then
        log_entry "W" "No AD groups found for [$adUser]"
        exit 0
    else
        local group_count
        group_count=$(printf '%s\n' "$ad_groups" | sed '/^$/d' | wc -l | tr -d ' ')
        log_entry "I" "Successfully retrieved [$group_count] AD groups for [$adUser]"
    fi

    mkdir -p "$cache_dir"
    printf '%s\n' "$ad_groups" > "$cache_file"
    log_entry "I" "Cached AD groups to [$cache_file]"
}

user_in_group() {
    local group="$1"

    if [[ -z "$group" ]]; then
        return 1
    fi

    if printf '%s\n' "$ad_groups" | grep -Fxq "$group"; then
        return 0
    fi

    return 1
}

# ---------------------------
# Shares in plist
# ---------------------------

plist_shares_count() {
    plist_print ":shares" | awk '/Dict[[:space:]]*{/{c++} END{print c+0}'
}

plist_share_url() {
    local idx="$1"
    plist_print ":shares:$idx:URL"
}

plist_share_mount() {
    local idx="$1"
    plist_print ":shares:$idx:localMount"
}

plist_share_groups() {
    local idx="$1"

    # PlistBuddy output formats vary (with or without numeric indexes). Handle both.
    # We extract only the actual group strings, one per line.
    plist_print ":shares:$idx:groups" |         sed -E 's/^[[:space:]]*[0-9]+[[:space:]]*=[[:space:]]*//; s/[",;]//g; s/^[[:space:]]+//; s/[[:space:]]+$//' |         awk 'NF>0 && $0 != "Array" && $0 != "{" && $0 != "}"'
}

# ---------------------------
# DC resolution for <<domaincontroller>>
# ---------------------------

get_domaincontroller() {
    local dc
    dc=$(dig +short _ldap._tcp.dc._msdcs."$domain" SRV | awk '{print $4}' | sed 's/\.$//' | head -n1)

    if [[ -z "$dc" ]]; then
        log_entry "W" "Could not resolve a domain controller via DNS SRV for [$domain]"
        return 1
    fi

    echo "$dc"
    return 0
}

resolve_share_url() {
    local url="$1"

    if [[ "$url" == *"<<domaincontroller>>"* ]]; then
        local dc
        dc=$(get_domaincontroller) || return 1
        url="${url/<<domaincontroller>>/$dc}"
    fi

    echo "$url"
    return 0
}


normalize_mountpoint() {
    # Always mount under the logged-in user's home directory to avoid requiring root
    # Example: /Volumes/Transfer -> /Users/<user>/Volumes/Transfer
    #          Transfer         -> /Users/<user>/Volumes/Transfer
    local requested="$1"
    local base

    if [[ -z "$requested" ]]; then
        echo ""
        return 1
    fi

    base=$(basename "$requested")
    echo "/Users/$loggedInUser/Volumes/$base"
    return 0
}

# ---------------------------
# Mount logic
# ---------------------------

is_mounted() {
    local mountpoint="$1"

    if mount | awk '{print $3}' | grep -Fxq "$mountpoint"; then
        return 0
    fi

    return 1
}

mount_share() {
    local url="$1"
    local mountpoint="$2"

    if [[ -z "$url" || -z "$mountpoint" ]]; then
        log_entry "E" "mount_share called with empty url or mountpoint"
        return 1
    fi

    if is_mounted "$mountpoint"; then
        log_entry "I" "Already mounted [$mountpoint], skipping"
        return 0
    fi

    if [[ ! -d "$mountpoint" ]]; then
        mkdir -p "$mountpoint"
        log_entry "I" "Created mountpoint [$mountpoint]"
    fi

    log_entry "I" "Mounting [$url] to [$mountpoint]"
    mount_out=$(/sbin/mount_smbfs "$url" "$mountpoint" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
    log_entry "E" "Mount failed for [$url] to [$mountpoint], rc=$rc, output: $mount_out"
    return 1
    fi


    log_entry "I" "Mount successful for [$mountpoint]"
    return 0
}

process_shares() {
    local count
    count=$(plist_shares_count)

    if [[ "$count" -le 0 ]]; then
        log_entry "W" "No shares found in plist [$preferences]"
        exit 0
    fi

    log_entry "I" "Found [$count] share entries in plist"

    user_volumes="/Users/$loggedInUser/Volumes"

    if [[ ! -d "$user_volumes" ]]; then
        mkdir -p "$user_volumes"
        chflags hidden "$user_volumes"
        log_entry "I" "Created and hid [$user_volumes]"
    fi

    local i
    for (( i=0; i<count; i++ )); do
        local raw_url url mountpoint

        raw_url=$(plist_share_url "$i")
        mountpoint=$(plist_share_mount "$i")
        mountpoint=$(normalize_mountpoint "$mountpoint")

        if [[ -z "$raw_url" || -z "$mountpoint" ]]; then
            log_entry "W" "Share index [$i] missing URL or localMount, skipping"
            continue
        fi

        url=$(resolve_share_url "$raw_url")
        if [[ $? -ne 0 || -z "$url" ]]; then
            log_entry "W" "Could not resolve URL for share index [$i], skipping"
            continue
        fi

        local should_mount="false"

        while IFS= read -r allowed_group; do
            if [[ -z "$allowed_group" ]]; then
                continue
            fi

            if user_in_group "$allowed_group"; then
                should_mount="true"
                break
            fi
        done < <(plist_share_groups "$i")

        if [[ "$should_mount" == "true" ]]; then
            log_entry "I" "User [$adUser] authorized for share [$url]"
            mount_share "$url" "$mountpoint"
        else
            log_entry "I" "User [$adUser] not authorized for share [$url], skipping"
        fi
    done
}

# ---------------------------
# Main
# ---------------------------

startLog
rotateLog
log_entry "I" "Logging execution of [$appname] to [$log]"

lockdir="/tmp/${appname}.lock"

if ! mkdir "$lockdir" 2>/dev/null; then
    log_entry "I" "Another instance is already running, exiting"
    exit 0
fi

trap 'rmdir "$lockdir" 2>/dev/null' EXIT


check_preferences
log_entry "I" "Configuration profile preferences found under $preferences"

load_env_from_preferences

load_kssoe_state

check_net
log_entry "I" "Corporate network is available for the Kerberos Single Sign On Extension"

check_auth
log_entry "I" "User is authenticated through the Kerberos Single Sign On Extension"

get_groups
process_shares
log_entry "I" "Fininshed logging execution of [$appname] to [$log]"