# CrazySpence's Capture the Flag

![Version](https://img.shields.io/badge/version-0.2.0-blue) ![Game](https://img.shields.io/badge/game-Vendetta%20Online-green)

A Capture the Flag mini-game plugin for [Vendetta Online](https://www.vendetta-online.com). Steal the enemy team's flag from their home station, carry it back to yours, and capture it — all while fighting off defenders and keeping your own flag safe.

---

## 🎮 Client Plugin

### Requirements

- Vendetta Online (any platform)

### Installation

1. Download the `csctf` plugin from [voupr](https://voupr.spenced.com) or clone this repository
2. Place the `csctf` folder in your Vendetta Online `plugins` directory
3. Launch the game — the plugin auto-downloads the latest version on each login

> **Note:** If the plugin fails to auto-update, run `/lua ReloadInterface()` in-game to force a fresh download. If your installed version is older than 0.2.0 you will need to re-download from voupr.

### Commands

| Command | Description |
|---|---|
| `/ctfstart` | Join CTF and connect to the game server |
| `/ctfstop` | Leave CTF and disconnect |
| `/ctfsay <message>` | Send a message to your team only |
| `/ctfscore` | Display your personal stats, bounty, and team totals |
| `/ctfhelp` | Show in-game rules, home stations, and tips |

### How to Play

Two teams compete to capture each other's flag:

- **Team 1** is based at **Sedina D-14**
- **Team 2** is based at **Bractus D-9**

**To capture the enemy flag:**
1. Fly to the enemy team's home station
2. Pick up their flag (it appears as a cargo item)
3. Carry it back to your own home station to score a point

**Flag rules:**
- Only one flag per team can be in play at a time
- If the carrier is destroyed, the flag drops in that sector
- If the flag goes uncarried for 3 minutes it resets back to the enemy station
- Manually dropping all cargo also drops the flag

### Scoring & Bounty

| Event | Bounty | Score |
|---|---|---|
| Flag capture | +500 | +500 |
| Flag assist *(carried flag in the same run as the capturer)* | +250 | +250 |
| Player kill | +100 | +victim's current bounty |
| Being killed | reset to 0 | — |

- **Bounty** is a session multiplier — the longer you survive, the more your kills are worth
- Bounty persists across disconnects and server restarts
- Use `/ctfscore` to see your score, bounty, captures, assists, and team totals at any time

### Reconnect Behaviour

If the connection to the game server drops:
- The plugin automatically retries **3 times at 30-second intervals**
- If all 3 attempts fail, CTF stops and you can manually rejoin with `/ctfstart`
- The server holds your flag carrier status for **60 seconds** after a restart — if you reconnect in time your run continues

---

## 🖥️ Server

### Requirements

- Perl with the following modules:
  - `Event`
  - `IO::Select`, `IO::Socket::INET`
  - `DBI`, `DBD::mysql`
  - `Storable`, `File::Copy`
- MySQL / MariaDB database
- TCP port **10500** open and accessible to players

### Configuration

Edit the `%OPTIONS` hash at the top of `main.pl`:

| Key | Default | Description |
|---|---|---|
| `DB_HOST` | `localhost` | MySQL host |
| `DB_PORT` | `3306` | MySQL port |
| `DB_USER` | | MySQL username |
| `DB_PASS` | | MySQL password |
| `DB_DB` | | MySQL database name |
| `STATE_FILE` | `./ctfstate.dat` | Path for game state persistence file |
| `DEBUG` | `1` | Set to `0` to daemonize and suppress verbose logging |

### Running

```bash
perl main.pl
```

The server listens on port 10500. When `DEBUG` is set to `0` it forks into the background automatically.

### Features

- **Persistent stats** — captures, assists, PKs, and total score stored in MySQL per player; columns are auto-migrated on startup
- **Game state persistence** — flag positions, carriers, and scores saved to disk on every action and restored after a crash or restart
- **Carrier recovery** — flag carriers have 60 seconds to reconnect after a server restart before their flag is reset
- **Version enforcement** — clients must be version 0.2.0 or newer; outdated plugins are disconnected with instructions to update
- **State file backups** — rolling `.1` / `.2` / `.3` backup rotation every 5 minutes
- **MySQL resilience** — automatically reconnects on connection loss; shuts down cleanly after 3 failed reconnect attempts

### Database

The `player_stat` table is created and migrated automatically on startup:

| Column | Type | Description |
|---|---|---|
| `name` | varchar | Player character name |
| `team` | int | Team assignment (1 or 2) |
| `captures` | int | Total flag captures |
| `assists` | int | Total flag capture assists |
| `pks` | int | Total player kills |
| `total_score` | int | Cumulative score across all sessions |

---

## Credits

Plugin by **CrazySpence**. TCP socket library by a1k0n. HTTP library by Fabian "firsm" Hirschmann.
