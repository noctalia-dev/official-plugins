# Bitwarden

Search your Bitwarden vault from the Noctalia launcher and copy login fields
via the official CLI’s local REST API (`bw serve`).

This plugin does **not** talk to the Bitwarden cloud Public API. Vault data is
zero-knowledge: decryption stays in the `bw` client. Self-hosted / Vaultwarden
servers work if you already pointed the CLI at them with `bw config server`
(or set **Server URL** in plugin settings before logging in).

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/bitwarden` |
| Entries | Service `service`, launcher `finder`, panels `unlock` / `login` |
| Launcher prefix | `/bw` |
| Dependency | `bitwarden-cli` (`bw` on `PATH`) |

## Requirements

Install **[bitwarden-cli](https://bitwarden.com/help/cli/)** so the `bw` binary
is on `PATH`. Distro package names vary (`bitwarden-cli`, `bw`, …).

## Setup

1. Install the Bitwarden CLI (see Requirements).
2. Log in once, either:
   - **In Noctalia:** `/bw` → **Log in** → personal API key (web vault:
     Settings → Security → Keys → View API key), then unlock with your master
     password; or
   - **In a terminal:** `bw login` / `bw login --apikey` (same end state,
     the plugin reuses the CLI session).
3. Optional for self-hosted / EU: set **Server URL** in plugin settings, or
   `bw config server https://your.server`.
4. Enable this plugin in Noctalia.

With **Auto-start serve** enabled (default), the service starts
`bw serve --hostname 127.0.0.1 --port <serve_port>` when the API is unreachable.

Disabling or uninstalling the plugin stops `bw serve` (including one you started
yourself), so the vault is no longer held in memory. Use **Log out** to stop
serve without disabling the plugin; restarting Noctalia leaves it running, with
the vault locked according to **Vault timeout**.

### Testing login again

`bw logout` alone is not enough: a running `bw serve` keeps the unlocked
vault in memory. Prefer the launcher **Log out** action (stops serve + CLI
logout), or:

```sh
# nix wraps bw as `node …/bw.js serve`: kill by port, not `pkill bw serve`
fuser -k 8087/tcp || true
bw logout
# confirm nothing is still serving secrets:
ss -ltnp | grep 8087 || echo "port free (good)"
curl -sS http://127.0.0.1:8087/status || echo "serve down (good)"
bw status
```

Then close and reopen the launcher (or re-type `/bw`). Reload/re-enable the
plugin if status still looks wrong.

## Usage

Open the launcher and type `/bw`:

| Result | Action |
| --- | --- |
| **Generate password** | Copies a new password (`GET /generate`; works locked) |
| **Generate passphrase** | Copies a new passphrase |
| **Log in** | Opens the API-key panel (when not logged in) |
| **Log out** | Stops `bw serve` and runs `bw logout` |
| **Unlock vault** | Opens a small password panel |
| **Lock vault** | Locks the local serve session |
| **Sync vault** | Pulls latest vault data |
| **Start bw serve** | Shown when serve is offline |
| Vault items | Listed when unlocked; Enter copies the configured field (password by default) |

When unlocked, `/bw` lists vault items (capped). Keep typing to filter by name, username, or URI.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `serve_port` | int | `8087` | Local `bw serve` port (127.0.0.1 only) |
| `auto_serve` | bool | `true` | Start `bw serve` when unreachable |
| `vault_timeout` | select | `on_restart` | Auto-lock after inactivity (`30`/`60`/`240` min), `on_restart`, `never` (until serve stops), or `custom` |
| `vault_timeout_custom_minutes` | int | `15` | Minutes when `vault_timeout` is `custom` (1–10080) |
| `server_url` | string | _(empty)_ | Passed to `bw config server` before API-key login |
| `copy_field` | select | `password` | Field to copy: password, username, totp, uri |
| `notify_on_copy` | bool | `true` | Notify after a successful copy |
| `clear_clipboard_seconds` | int | `0` | Clear clipboard after N seconds if unchanged (`0` = off) |
| `gen_length` | int | `20` | Generated password length |
| `gen_uppercase` / `gen_lowercase` / `gen_number` / `gen_special` | bool | `true`/`true`/`true`/`false` | Password charset |
| `gen_passphrase_words` | int | `4` | Passphrase word count |
| `gen_passphrase_separator` | string | `-` | Word separator |
| `gen_passphrase_capitalize` | bool | `false` | Capitalize passphrase words |
| `gen_passphrase_include_number` | bool | `false` | Append a number to the passphrase |

## IPC

```sh
noctalia msg plugin noctalia/bitwarden:service all ensure_serve
noctalia msg plugin noctalia/bitwarden:service all status
noctalia msg plugin noctalia/bitwarden:service all lock
noctalia msg plugin noctalia/bitwarden:service all logout
noctalia msg plugin noctalia/bitwarden:service all sync
noctalia msg plugin noctalia/bitwarden:service all generate
noctalia msg plugin noctalia/bitwarden:service all generate passphrase
noctalia msg panel-toggle noctalia/bitwarden:login
noctalia msg panel-toggle noctalia/bitwarden:unlock
```

Do not pass API secrets or the master password on the CLI. Use the panels.

## Security

- Serve is bound to **127.0.0.1** only. While the vault is unlocked, any local
  process that can reach that port can read vault secrets. Prefer a vault timeout
  and lock when idle.
- Master passwords and API keys are never stored in plugin settings or on disk.
- Shell `offline_mode` blocks launcher HTTP to `bw serve` until it is off.
- Generate uses warm `bw serve` (`GET /generate`), CLI fallback if unreachable.
