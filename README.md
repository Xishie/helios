# HELIOS

## What it does

HELIOS runs as a set of LaunchAgents, checks whether the user is authenticated through the Kerberos SSO Extension, queries Active Directory for group memberships via LDAP, and mounts SMB shares the user is authorized for.

## How it works

1. Reads share definitions from a managed preferences plist deployed via a configuration profile
2. Validates that the corporate network is reachable and the user is authenticated via KSSOE
3. Looks up the user's AD group memberships (cached for 4 hours to reduce DC load)
4. For each share, checks if the user belongs to any of the allowed groups
5. Mounts authorized shares under `~/Volumes/`

## Requirements

- macOS with the Kerberos Single Sign On Extension configured
- An MDM for the configuration profile deployment

## Components

|File|Installs to|Description|
|---|---|---|
|`helios.sh`|`/Library/helios/helios.sh`|Main script|
|`sso_bundle.app`|`/Library/helios/sso_bundle.app`|Helper app that listens for KSSOE notifications|
|`io.github.xishie.helios.timer.plist`|`/Library/LaunchAgents/`|Runs helios on a 15-minute schedule|
|`io.github.xishie.helios.ConnectionCompleted.plist`|`/Library/LaunchAgents/`|Triggers on Kerberos connection completed|
|`io.github.xishie.helios.gotNewCredential.plist`|`/Library/LaunchAgents/`|Triggers on new Kerberos credential|
|`io.github.xishie.helios.InternalNetworkAvailable.plist`|`/Library/LaunchAgents/`|Triggers when internal network becomes available|

## Configuration profile

The configuration profile uses the preference domain `io.github.xishie.helios` and expects the following keys:

|Key|Type|Description|
|---|---|---|
|`realm`|String|Your Kerberos realm (e.g. `CORP.EXAMPLE.COM`)|
|`domain`|String|Your AD domain (e.g. `corp.example.com`)|
|`domainPath`|String|Your LDAP base DN (e.g. `DC=corp,DC=example,DC=com`)|
|`shares`|Array|An array of share dictionaries|

Each share dictionary contains:

|Key|Type|Description|
|---|---|---|
|`URL`|String|The SMB path to the share. Use `<<domaincontroller>>` as a placeholder to auto-resolve a DC via DNS SRV|
|`localMount`|String|The desired mount name (mounted under `~/Volumes/`)|
|`groups`|Array|AD groups authorized to access this share|

An example mobileconfig is included in `MobileConfig/`.

## LaunchAgents

HELIOS uses four LaunchAgents. The timer agent runs the script every 900 seconds (15 minutes) by default. You can change this by editing the `StartInterval` key:

```xml
<key>StartInterval</key>
<integer>900</integer>
```

The other three agents use `sso_bundle.app` to listen for Darwin notifications from the Kerberos SSO Extension. They trigger helios immediately when the user authenticates, gets new credentials, or when the internal network becomes available. This means shares mount right away instead of waiting for the next timer interval.

All four agents have `KeepAlive` and `RunAtLoad` set to `true`.

## Logs and cache

Logs are written to `~/Library/Logs/helios/helios.log` and automatically rotated when they exceed 1 MB.

The AD groups cache is written to `~/Library/Caches/helios/ad_groups.txt` and refreshed every 4 hours.

## Packaging for Munki

Assumes you have [munkipkg](https://github.com/munki/munki-pkg) installed.

### 1. Clone the repo

```bash
git clone https://github.com/Xishie/helios.git ~/Downloads/helios
```

### 2. Create the munkipkg folder structure

```bash
munkipkg --create helios-pkg
mkdir -p helios-pkg/payload/Library/helios
mkdir -p helios-pkg/payload/Library/LaunchAgents
```

### 3. Copy files into the payload

```bash
cp ~/Downloads/helios/helios.sh helios-pkg/payload/Library/helios/
cp ~/Downloads/helios/Helper/sso_bundle.app helios-pkg/payload/Library/helios/
cp ~/Downloads/helios/LaunchAgents/*.plist helios-pkg/payload/Library/LaunchAgents/
```

### 4. Copy the scripts

The postinstall handles loading the LaunchAgents. The postuninstall is not part of the pkg -- add it to the munki pkginfo as `uninstall_script`.

```bash
cp ~/Downloads/helios/Scripts/postinstall.sh helios-pkg/scripts/postinstall
```

### 5. Set permissions

```bash
# Payload
chmod 755 helios-pkg/payload/Library/helios
chmod +x helios-pkg/payload/Library/helios/helios.sh
chmod 644 helios-pkg/payload/Library/LaunchAgents/*.plist

# Scripts
chmod +x helios-pkg/scripts/postinstall
```

### 6. Update build-info.plist

```xml
<key>identifier</key>
<string>io.github.xishie.helios</string>
<key>name</key>
<string>helios-${version}.pkg</string>
<key>version</key>
<string>1.0</string>
```

### 7. Build

```bash
munkipkg helios-pkg/
```

The built pkg will be in `helios-pkg/build/`.

### Munki pkginfo notes

The postinstall script handles loading the LaunchAgents into the current user's GUI session. If no user is logged in (e.g. during Munki bootstrap mode or DEP enrollment), it exits cleanly and the agents will load automatically at the next user login via `RunAtLoad`.

For uninstalls, add the contents of `Scripts/postuninstall.sh` as the `uninstall_script` in your pkginfo. It boots out the agents, disables them, removes all plists, cleans up per-user logs and caches, and forgets the pkg receipt.

## Verifying the install

Check that the agents are loaded and not disabled:

```bash
launchctl print gui/$(id -u) | grep "io.github.xishie.helios"
```

You should see the four agents listed with PIDs and no `disabled` overrides.