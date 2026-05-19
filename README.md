# HELIOS

## What it does

HELIOS runs periodically via a LaunchAgent, checks whether the user is
authenticated through the Kerberos SSO Extension, queries Active Directory for
group memberships via LDAP, and mounts the SMB shares the user is authorized
for.

It is a small Swift command-line tool. Mounting goes through the **NetFS
framework** (`NetFSMountURLSync`) — the same engine Finder / "Connect to
Server" uses — which means:

- **Windows DFS is followed transparently**, including nested per-folder DFS
  junctions. `mount_smbfs` does *not* follow these, which is why a plain
  `mount_smbfs` approach fails on DFS namespaces.
- It mounts with the **NoUI** option, so it never shows an authentication
  dialog: silent success when a Kerberos ticket is present, a logged error
  otherwise.
- The mount is not Finder-adopted, so a network/VPN drop produces a single
  DiskArbitration notification rather than a reconnect dialog per share.

## How it works

1. Reads share definitions from a managed preferences plist deployed via a
   configuration profile.
2. Validates that the corporate network is reachable and the user is
   authenticated via KSSOE (`app-sso`).
3. Looks up the user's recursive AD group memberships
   (`ldapsearch -Y GSSAPI`, cached for 4 hours to reduce DC load).
4. For each share, checks if the user belongs to any of the allowed groups.
5. Mounts authorized shares via NetFS under `/Volumes/`.

The single-instance lock, AD-group cache, deterministic domain-controller
selection, log format, and exit-0-on-not-ready behaviour are preserved from
earlier versions, so existing log tooling keeps working.

## Requirements

- macOS 12 or later, with the Kerberos Single Sign On Extension configured
- An MDM for the configuration profile deployment
- Xcode / Swift toolchain to build (build host only)

## Components

| File | Installs to | Description |
|------|-------------|-------------|
| `helios` (built from `Sources/`) | `/Library/helios/helios` | The signed binary |
| `io.github.xishie.helios.timer.plist` | `/Library/LaunchAgents/` | Runs helios on a 60-second schedule |

## Configuration profile

The configuration profile uses the preference domain `io.github.xishie.helios`
and expects the following keys:

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
| `groups` | Array | AD groups authorized to access this share |

> The mount name is derived from the **last path component of the URL**
> (`smb://host/srf-tpc/EFS` → `/Volumes/EFS`). This is stable regardless of
> which `<<domaincontroller>>` the URL resolves to. A `localMount` key, if
> present in your existing profile, is ignored — NetFS controls the mount
> name and always mounts under `/Volumes/`.

An example mobileconfig is included in `MobileConfig/`.

## LaunchAgent

The timer agent runs helios every 60 seconds by default. Change this via the
`StartInterval` key in the plist:

```xml
<key>StartInterval</key>
<integer>60</integer>
```

`RunAtLoad` is `true`, so it also runs immediately when the user logs in.

## Logs and cache

Logs are written to `~/Library/Logs/helios/helios.log` and rotated when they
exceed 1 MB.

The AD groups cache is written to `~/Library/Caches/helios/ad_groups.txt` and
refreshed every 4 hours.

## Building

```bash
git clone https://github.com/Xishie/helios.git
cd helios
swift build -c release --arch arm64 --arch x86_64
```

The universal binary is written to
`.build/apple/Products/Release/helios`.

### Signing

A binary run by launchd benefits from a stable code identity. Sign it with
your own **Developer ID Application** certificate:

```bash
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: YOUR ORG (TEAMID)" \
  .build/apple/Products/Release/helios
codesign --verify --strict --verbose=2 .build/apple/Products/Release/helios
```

`--timestamp` keeps the signature valid after the certificate expires.
`--options runtime` (hardened runtime) is optional but makes the binary
notarization-ready.

> The signed binary and the built pkg are intentionally **not** committed to
> this repository — build and sign with your own certificate.

### Packaging

```bash
STAGE=/tmp/heliosbuild
rm -rf "$STAGE"
mkdir -p "$STAGE/root/Library/helios" "$STAGE/root/Library/LaunchAgents" "$STAGE/scripts"
cp .build/apple/Products/Release/helios "$STAGE/root/Library/helios/helios"
cp LaunchAgents/io.github.xishie.helios.timer.plist "$STAGE/root/Library/LaunchAgents/"
cp Scripts/postinstall.sh "$STAGE/scripts/postinstall"
chmod 755 "$STAGE/root/Library/helios/helios" "$STAGE/scripts/postinstall"
chmod 644 "$STAGE/root/Library/LaunchAgents/"*.plist
xattr -cr "$STAGE"

pkgbuild --root "$STAGE/root" \
  --identifier io.github.xishie.helios \
  --version 2.0.0 \
  --scripts "$STAGE/scripts" \
  --install-location / \
  /tmp/helios-unsigned.pkg

productsign --sign "Developer ID Installer: YOUR ORG (TEAMID)" \
  /tmp/helios-unsigned.pkg /tmp/helios-2.0.0.pkg
```

Stage and build on a local disk, not a cloud-synced folder — `pkgbuild` and
`installer` can stall mid-extraction reading from a FileProvider mount.

**Notarization is not required** for MDM/munki deployment: pkgs installed by
munki or an MDM are not quarantined, so Gatekeeper never evaluates them. The
binary is notarization-ready if you ever need it (`xcrun notarytool submit`).

### Munki

Keep the package `identifier` as `io.github.xishie.helios` and bump
`--version` per release — munki then treats it as an upgrade of the existing
install rather than a parallel one. Add the contents of
`Scripts/postuninstall.sh` as the `uninstall_script` in your pkginfo.

The postinstall script loads the timer LaunchAgent into the current user's
GUI session, removes any legacy `helios.sh` from helios 1.x, and clears the
AD-groups cache so nested membership is re-evaluated immediately after an
update. If no user is logged in (Munki bootstrap, DEP enrollment), it exits
cleanly and the agent loads at next login via `RunAtLoad`.

## Verifying the install

```bash
launchctl print gui/$(id -u) | grep "io.github.xishie.helios"
tail -f ~/Library/Logs/helios/helios.log
```

You should see the timer agent listed with a PID and no `disabled` override,
and the log should show authorized shares mounting once, then steady
`Already mounted … skipping` on subsequent runs.
