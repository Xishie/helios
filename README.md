# HELIOS

## What it does

HELIOS runs periodically via a LaunchAgent, checks whether the user is authenticated through the Kerberos SSO Extension, queries Active Directory for group memberships via LDAP, and mounts SMB shares the user is authorized for.

## How it works

1. Reads share definitions from a managed preferences plist deployed via a configuration profile
2. Validates that the corporate network is reachable and the user is authenticated via KSSOE
3. Looks up the user's AD group memberships (cached for 4 hours to reduce DC load)
4. For each share, checks if the user belongs to any of the allowed groups
5. Mounts authorized shares under `~/Volumes/`

## Requirements

- macOS with the Kerberos Single Sign On Extension configured
- An MDM for the configuration profile deployment

## Components

| File | Installs to | Description |
|------|-------------|-------------|
| `helios.sh` | `/Library/helios/helios.sh` | Main script |
| `io.github.xishie.helios.timer.plist` | `/Library/LaunchAgents/` | Runs helios on a 60-second schedule |

## Configuration profile

The configuration profile uses the preference domain `io.github.xishie.helios` and expects the following keys:

| Key | Type | Description |
|-----|------|-------------|
| `realm` | String | Your Kerberos realm (e.g. `CORP.EXAMPLE.COM`) |
| `domain` | String | Your AD domain (e.g. `corp.example.com`) |
| `domainPath` | String | Your LDAP base DN (e.g. `DC=corp,DC=example,DC=com`) |
| `shares` | Array | An array of share dictionaries |

Each share dictionary contains:

| Key | Type | Description |
|-----|------|-------------|
| `URL` | String | The SMB path to the share. Use `<<domaincontroller>>` as a placeholder to auto-resolve a DC via DNS SRV |
| `localMount` | String | The desired mount name (mounted under `~/Volumes/`) |
| `groups` | Array | AD groups authorized to access this share |

An example mobileconfig is included in `MobileConfig/`.

## LaunchAgent

The timer agent runs the script every 60 seconds by default. You can change this by editing the `StartInterval` key in the plist:

```xml
<key>StartInterval</key>
<integer>60</integer>
```

The agent has `RunAtLoad` set to `true`, so it also runs immediately when the user logs in.

## Notification agents (optional)

The `LaunchAgents/` directory also includes three additional agents that use `sso_bundle.app` (in `Helper/`) to listen for KSSOE Darwin notifications and trigger helios immediately on authentication events. These are more responsive but can cause issues over VPN or during sleep/wake cycles where network transitions fire multiple events in quick succession.

If you want to use them, use `postinstall-full.sh` and `postuninstall-full.sh` instead of the default scripts, and include `sso_bundle.app` and all four plists in your pkg payload.

| File | Triggers on |
|------|-------------|
| `io.github.xishie.helios.ConnectionCompleted.plist` | Kerberos connection completed |
| `io.github.xishie.helios.gotNewCredential.plist` | New Kerberos credential acquired |
| `io.github.xishie.helios.InternalNetworkAvailable.plist` | Internal network becomes available |

## Logs and cache

Logs are written to `~/Library/Logs/helios/helios.log` and automatically rotated when they exceed 1 MB.

The AD groups cache is written to `~/Library/Caches/helios/ad_groups.txt` and refreshed every 4 hours.

## Packaging for Munki

Assumes you have [munkipkg](https://github.com/munki/munki-pkg) installed.

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
cp ~/Downloads/helios/LaunchAgents/io.github.xishie.helios.timer.plist helios-pkg/payload/Library/LaunchAgents/
```

### 4. Copy the postinstall script

```bash
cp ~/Downloads/helios/Scripts/postinstall.sh helios-pkg/scripts/postinstall
```

The postuninstall is not part of the pkg, add it to the munki pkginfo as `uninstall_script`.

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

The built pkg will be in `helios-pkg/build/`.

### Munki pkginfo notes

The postinstall script loads the timer LaunchAgent into the current user's GUI session. If no user is logged in (e.g. during Munki bootstrap mode or DEP enrollment), it exits cleanly and the agent will load automatically at the next user login via `RunAtLoad`.

For uninstalls, add the contents of `Scripts/postuninstall.sh` as the `uninstall_script` in your pkginfo. It boots out the agent, disables it, removes the plist, cleans up per-user logs and caches, and forgets the pkg receipt.

## Verifying the install

Check that the agent is loaded and not disabled:

```bash
launchctl print gui/$(id -u) | grep "io.github.xishie.helios"
```

You should see the timer agent listed with a PID and no `disabled` override.