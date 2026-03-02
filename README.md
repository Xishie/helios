# Hybrid Enterprise Logon-aware Identity-based Orchestration for Shares
HELIOS is a macOS bash tool that leverages the Kerberos Single Sign On Extension to mount shares based on active directory groups. And it has a uselessly complex acronym.

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

Deploy these using whatever method works for your environment — MDM, Munki, or otherwise. Just make sure the script is executable and the configuration profile is customized for your environment before deploying.

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

## Logs & Groups Cache

Logs are written to `~/Library/Logs/helios/helios.log` and are automatically rotated when they exceed 1 MB.

The Cache is written to `~/Library/Caches/helios/ad_groups.txt`.