# RobloxVerify

Lightweight Linux service that watches a list of Roblox users and pushes a
notification to your phone the moment they go online, start playing a game or
disconnect.

It is a single Bash script plus a systemd unit — no daemons, no database, no
build step.

## How it works

1. `roblox_verify.sh` reads its configuration from a local `.env` file
   (a list of user IDs and an ntfy topic).
2. Every polling cycle it asks the **Roblox Presence API**
   (`POST https://presence.roblox.com/v1/presence/users`) for the state of each
   tracked user.
3. When a user's state differs from the last observed one, it posts a message
   to your **ntfy.sh** topic.

Roblox presence values:

| Value | Meaning        | Notification       |
|-------|----------------|--------------------|
| `0`   | Offline        | "went offline"     |
| `1`   | Online         | "is online"        |
| `2`   | In game        | "started playing"  |

The first poll of each user only records the baseline state, so you get
notifications on *changes*, not on startup.

## Requirements

- `bash`
- `curl`
- `jq`
- `systemd` (any modern Linux distribution)

On Arch / CachyOS / Manjaro:

```bash
sudo pacman -S curl jq
```

## Configuration

Your Roblox IDs and ntfy topic are private, so they live in a `.env` file that
is **gitignored** and never uploaded.

```bash
cp .env.example .env
```

Then edit `.env`:

```bash
# Tracked users, as "<robloxUserId>:<label>"
USERS=("1493909199:Alice" "370166776:Bob")

# ntfy.sh topic that receives the notifications
TOPIC="my_ntfy_topic"
```

> **Tip:** to keep your ntfy topic private, generate a long random string, e.g.
> `openssl rand -hex 16`. Anyone who knows the topic can post and read your
> notifications.

Optional timings (defaults shown):

```bash
REQUEST_DELAY=3   # seconds between per-user requests
CYCLE_DELAY=35    # seconds between full polling cycles
```

## Installation

```bash
sudo ./install.sh
```

The installer:

- detects the target user automatically (`SUDO_USER`, `PKEXEC_UID`, `USER` or
  `logname`) — override it with `sudo SERVICE_USER=someone ./install.sh`;
- renders `roblox-verify.service`, replacing the `__USER__` and
  `__SCRIPT_DIR__` placeholders with the detected values;
- installs it to `/etc/systemd/system/roblox-verify.service`;
- enables and starts it, then prints the service status.

```bash
# Logs (live)
journalctl -u roblox-verify.service -f

# Restart / stop
sudo systemctl restart roblox-verify.service
sudo systemctl stop roblox-verify.service

# Uninstall (leaves the script and .env untouched)
sudo ./install.sh --uninstall
```

## Repository layout

| File                    | Purpose                                              |
|-------------------------|------------------------------------------------------|
| `roblox_verify.sh`      | The monitor itself.                                   |
| `install.sh`            | Installs / uninstalls the systemd service.            |
| `roblox-verify.service` | systemd unit **template** (placeholders, not usable as-is). |
| `.env.example`          | Sample configuration.                                 |
| `.env`                  | Your real configuration — gitignored.                 |

## Notes

- No authentication is used against Roblox or ntfy, so keep polling delays
  polite (the defaults are conservative).
- The service runs with a hardened systemd sandbox
  (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`, `ProtectHome`).
- Run it manually for a quick test with `./roblox_verify.sh` (Ctrl+C to stop).