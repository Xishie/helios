# HELIOS
## What it does

HELIOS runs periodically via a LaunchDaemon, checks whether the user is authenticated through the Kerberos SSO Extension, queries Active Directory for group memberships via LDAP, and mounts SMB shares the user is authorized for — all without user interaction.

## How it works

1. Reads share definitions from a managed preferences plist deployed via a configuration profile
2. Validates that the corporate network is reachable and the user is authenticated via KSSOE
3. Looks up the user's AD group memberships (cached for 4 hours to reduce DC load)
4. For each share, checks if the user belongs to any of the allowed groups
5. Mounts authorized shares under `~/Volumes/`

## Requirements

- macOS with the Kerberos Single Sign On Extension configured
- `jq` installed on the device — usually included in the standard macOS installation
- An MDM for the configuration profile deployment

## Deployment

HELIOS consists of three components:

| File | Description |
|------|-------------|
| `helios.sh` | The main script |
| `io_github_xishie_helios_timer.plist` | LaunchDaemon that runs the script on a schedule |
| `io_github_xishie_helios_example.mobileconfig` | Example configuration profile containing share definitions |

You can deploy the packaged version or build your own.

## Configuration profile

The configuration profile expects the following keys:

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

Don't forget to change the path of the script in the LaunchAgent if you're not deploying it to `/Library/Application\ Support/helios/helios.sh`

## LaunchAgent

The included LaunchAgent triggers the script every 60 seconds. You can either change the timing by changing the start interval key.

```xml
<key>StartInterval</key>
<integer>60</integer>
```

Or you can use your own LaunchAgent(s) too if you need more precise triggers.

## Logs & Groups Cache

Logs are written to `~/Library/Logs/helios/helios.log` and are automatically rotated when they exceed 1 MB.

The Cache is written to `~/Library/Caches/helios/ad_groups.txt`.

## Packaging HELIOS for Munki
If you don't want to use the provided package and assuming you have munkipkg installed, you can:

### 1. Clone this repository in your to your Downloads to make your life easier

```bash
git clone https://github.com/Xishie/helios.git
```

### 2. Create a the folder structure for munki

```bash
munkipkg --create helios
mkdir helios/payload/Library/Application\ Support/helios
mkdir -p helios/payload/Library/LaunchAgents
```

### 3. Copy the downloaded repository files to the munki folder

```bash
cp ~/Downloads/helios/helios.sh helios/payload/Library/Application\ Support/helios/helios.sh
cp ~/Downloads/helios/io_github_xishie_helios_timer.plist helios/payload/Library/LaunchAgents/io.github.xishie.helios.timer.plist
cp ~/Downloads/helios/Scripts/preinstall.sh helios/scripts/preinstall
cp ~/Downloads/helios/Scripts/postinstall.sh helios/scripts/postinstall
cp ~/Downloads/helios/Scripts/postuninstall.sh helios/scripts/postuninstall
```

### 4. Change the permissions

```bash
chmod +x helios/payload/Library/Application\ Support/helios/helios.sh
chmod +x helios/scripts/preinstall
chmod +x helios/scripts/postinstall
chmod +x helios/scripts/postuninstall
```

### 5. Update the following keys in the build-info.plist

```xml
<key>identifier</key>
<string>io.github.xishie.helios</string>
<key>name</key>
<string>helios-1.0.pkg</string>
<key>version</key>
<string>1.0</string>
```