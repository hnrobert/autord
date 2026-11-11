# autord

**One command to install and configure the RustDesk remote desktop on Linux** — latest release, LAN access, password access, optional self-hosted server config.

```bash
# Interactive wizard over the pipe (asks: access -> servers -> password)
curl -fsSL https://raw.githubusercontent.com/hnrobert/autord/main/autord.sh | sudo bash -s --
```

## Features

- **Latest version, automatically**: resolves the newest GitHub release (currently 1.5.0) and picks the right
  package per distro (Debian/Ubuntu `.deb`, Fedora/RHEL `.rpm`, openSUSE `-suse.rpm`, Arch `.pkg.tar.zst`;
  falls back to AppImage when nothing matches)
- **Background download with cache**: the install state and the package cache
  (`/var/cache/autord`) are checked before the first question; if a download is needed it starts
  immediately in the background and overlaps with the wizard/confirm, so there is usually nothing
  left to wait for by the time you finish answering. Partial downloads resume across runs;
  re-installs reuse the cached package; `--uninstall` clears the cache
- **LAN access**: enables `enable-lan-discovery` (LAN discovery) + `direct-server` (direct IP access,
  optional port) by default
- **Remote config modification**: enables `allow-remote-config-modification` by default, so the
  controlling side can change settings on this machine (opt out with `--no-remote-config-modification`)
- **Password access**: sets a permanent password (manual or random, shown once) plus
  `verification-method = use-permanent-password`
- **Self-hosted ID/relay servers**, two ways:
  - **Config string**: paste the base64 string from the client's `Settings -> Network -> Export Server Config`
    (the `host=xx,key=xx,relay=xx,api=xx` form also works), applied via `rustdesk --config`
  - **Individual flags**: `--id-server` / `--relay-server` / `--api-server` / `--key`
  - Values are **verified by readback** after writing; if `--config` skipped a field (relay was historically
    dropped by a bug) it is re-applied automatically
- **Dual mode**: unattended via flags / interactive wizard when run without args (prompts go through
  `/dev/tty`, so `curl | bash` still works)
- **IPC fallback**: the rustdesk CLI needs root + a reachable service process; when unavailable the script
  writes `RustDesk2.toml` directly and restarts the service
- `--status`, `--uninstall` (keeps user configs), `--dry-run`

## Requirements

- Linux x86_64 / aarch64, bash 4+, `curl`, root (`--dry-run` and `--status` do not need root)
- `python3` optional (more robust TOML editing and base64 config-string parsing)
- Wayland users: there is an official headless Wayland build (`rustdesk-unattended-wayland-*`);
  this script installs the standard package

## Quick start

```bash
# Interactive wizard (asks: LAN -> servers -> password)
sudo ./autord.sh

# Fully unattended: default public servers + random password (shown once at the end)
sudo ./autord.sh --yes --random-password

# Unattended + self-hosted servers (string from the client's "Export Server Config")
sudo ./autord.sh --yes --random-password --config-string 'aG9zdD1ycy5leGFtcGxlLmNvbSxrZXk9S0s='

# Unattended + self-hosted servers (individual flags)
sudo ./autord.sh --yes \
  --id-server rs.example.com:21116 \
  --relay-server relay.example.com:21117 \
  --key 'OaVaBKeyIs3JwERcG1Qvw==' \
  --password 'your-password'

# Preview actions without changing anything (no root needed)
./autord.sh --dry-run --yes --random-password

# Show status / uninstall (configs are kept)
sudo ./autord.sh --status
sudo ./autord.sh --uninstall
```

## Options

| Flag | Description | Default |
|---|---|---|
| `--yes`, `-y` | Skip all confirmations | ask |
| `--version <ver>` | Pin a version (e.g. `1.5.0`) | latest |
| `--mirror <prefix>` | GitHub download prefix, replaces `https://github.com` wholesale | none |
| `--force` | Reinstall even if the same version is installed | skip |
| `--no-lan-discovery` | Do not enable LAN discovery | on |
| `--no-direct-server` | Do not enable direct IP access | on |
| `--no-remote-config-modification` | Do not allow the controlling side to change settings | on |
| `--direct-port <port>` | Direct IP access port | 21118 |
| `--config-string <s>` | Server config string exported by the client | none |
| `--id-server <host[:port]>` | Custom ID server | none |
| `--relay-server <host[:port]>` | Custom relay server | none |
| `--api-server <url>` | API server (Pro) | none |
| `--key <pubkey>` | Server public key | none |
| `--password <pw>` | Set the permanent password | none |
| `--random-password` | Generate a random 12-char permanent password (shown once in the summary) | none |
| `--status` | Read-only status report | — |
| `--uninstall` | Uninstall (user configs are kept) | — |
| `--dry-run` | Print actions only | off |
| `--help`, `-h` | Help | — |

Rules: `--password` and `--random-password` are mutually exclusive; `--config-string` and the four
server flags are mutually exclusive.

**Environment variable equivalents** (command line wins): `RD_YES` `RD_PASSWORD` `RD_RANDOM_PASSWORD`
`RD_CONFIG_STRING` `RD_ID_SERVER` `RD_RELAY_SERVER` `RD_API_SERVER` `RD_KEY` `RD_NO_LAN_DISCOVERY`
`RD_NO_DIRECT_SERVER` `RD_NO_REMOTE_CONFIG_MODIFICATION` `RD_DIRECT_PORT` `RD_VERSION` `RD_MIRROR` `RD_DRY_RUN`

```bash
curl -fsSL <url>/autord.sh | sudo RD_YES=1 RD_RANDOM_PASSWORD=1 bash -s --
```

## Interactive wizard

Run without arguments to start the wizard.

If RustDesk **is already installed**, the wizard first asks in order:

0. Update? — `Upgrade to <latest> [Y/n]` when an older version is found
   (or `Reinstall <same version> [y/N]`; `--force` flips the default to Y), then
   `Re-apply configuration (LAN, password, servers) [Y/n]` — answering `n` skips the
   wizard and just prints the summary (e.g. update-only runs)

Then the configuration questions:

1. Access: LAN discovery? direct IP access + port? allow remote config modification?
2. Servers: paste the exported config string (Enter to skip); if skipped, each of id/relay/api/key is asked
3. Password: `[1]` enter manually (hidden input) `[2]` random `[3]` skip
4. The plan is printed; confirm to execute

> The wizard reads `/dev/tty`, so it works under `curl ... | sudo bash` pipes.
> Without a terminal (CI, `ssh host 'sudo ./autord.sh'` without a tty) and without flags, the script
> prints a hint to use flags and exits instead of hanging.

## How it works

The RustDesk client's own CLI *is* the config editor (no third-party tool needed):

| Command | Effect |
|---|---|
| `rustdesk --config <string>` | Apply the exported server config string |
| `rustdesk --option <k> <v>` | Read/write any option (`enable-lan-discovery`, `direct-server`, `verification-method`, ...) |
| `rustdesk --password <pw>` | Set the permanent password |
| `rustdesk --get-id` | Print this machine's ID |

These commands require **rustdesk installed + root + a reachable rustdesk service process (IPC)**.
When IPC is unavailable (no desktop session, container without systemd, ...), autord falls back to
upserting the keys in the `[options]` section of `RustDesk2.toml` (both root's and the desktop user's
copy), then restarts the service.
**The one exception is the permanent password** — it is stored encrypted and can only be set through
the CLI/GUI. In fallback mode the script warns and skips it; set it later in the client under
`Settings -> Security`, or run `sudo rustdesk --password '<password>'` once the service is healthy.

## FAQ

- **GitHub downloads slow or rate-limited?** Try `--mirror https://ghproxy.example/https://github.com`.
  If version resolution fails, pin with `--version 1.5.0` (the script also falls back to parsing the
  releases page 302 redirect automatically).
- **Container without systemd?** The service process is started directly with `nohup` (best effort) and
  options go through the TOML fallback path.
- **AppImage limitations?** No systemd service and no IPC -> the password cannot be set via CLI and
  options use the TOML fallback; without FUSE you need `--appimage-extract-and-run`. Arch on aarch64 has
  no official package, so the script falls back to AppImage (or use the AUR `rustdesk` package).
- **Cannot connect?** Open TCP 21115-21119 (hbbs/hbbr) for cross-subnet / self-hosted setups; direct IP
  access uses port 21118 by default.
- **Where is the downloaded package?** In `/var/cache/autord` (reused on re-runs; `.part` files are
  interrupted downloads and resume automatically; delete them to start fresh).
- **How to change a written option?** Re-run the script with new flags (upserts are idempotent), or
  `sudo rustdesk --option <k> <v>` directly.
- **Re-running on an installed machine?** Interactively you are asked whether to update and whether
  to re-apply the config. Unattended (`--yes`), a newer release is installed automatically and the
  same version is left alone (`--force` reinstalls); configuration flags are always re-applied, and
  `--yes` without config flags applies the defaults (LAN/direct/remote-config on).
  "Installed" means the rustdesk **executable** exists (found on `PATH` or in `/usr/bin`,
  `/usr/local/bin`, `/bin`, `/opt/rustdesk/`); the version from `rustdesk --version` is a best-effort
  probe — an unreadable version is reported as *unknown* and reinstall is offered as the repair path.

## Development & tests

```bash
bash -n autord.sh            # syntax
shellcheck autord.sh         # static analysis (0 warnings)
bash test/run.sh             # source-mode unit tests (no root needed)
./autord.sh --dry-run --yes  # full-pipeline preview
```

Test seam: `AUTORD_FORCE_NO_IPC=1` forces the TOML fallback path for verification.
See `test/REALTEST.md` for the full on-metal acceptance checklist.

## License

MIT
