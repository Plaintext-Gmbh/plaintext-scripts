# plaintext-scripts

Shared build, release, deployment pipeline and developer tools for Maven-based projects with Docker and blue-green deployments to a NAS.

## Overview

This repository provides a reusable TUI-based build system and developer tools:

**Build & Deploy**
- **Maven builds** (SNAPSHOT and release)
- **Semantic versioning** (major, minor, patch) with auto-increment
- **Docker image builds** (Podman on macOS, Docker on Linux)
- **Blue-green deployments** to a Synology NAS with zero downtime
- **Health checks** with automatic rollback on failure
- **Database backups** (PostgreSQL) before production deployments
- **Interactive TUI menu** and CLI multi-command execution (e.g. `./build 56`)

**Developer Tools**
- **Voice-to-Claude** — Voice-controlled interaction with Claude Code (speech-to-text, screenshots, clipboard, batch mode)

## Installation

The `build` script in your project automatically clones this repository to `~/.plaintext-scripts` on first run. No manual installation required.

To update manually:

```bash
git -C ~/.plaintext-scripts pull
```

Or set `PLAINTEXT_SCRIPTS_UPDATE=true` before running `./build` for a one-time auto-update.

## Project Setup

### 1. Create a `build` script in your project root

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SCRIPTS_DIR="$HOME/.plaintext-scripts"
if [ ! -d "$SCRIPTS_DIR/.git" ]; then
    git clone git@github.com:Plaintext-Gmbh/plaintext-scripts.git "$SCRIPTS_DIR"
fi
source "$SCRIPTS_DIR/tui-common.sh"
source "$SCRIPTS_DIR/tui-build-logic.sh"

init_versions

# ... TUI menu and command dispatch (see plaintext-root for a full example)
```

### 2. Create `build-conf.txt`

Copy the template and adjust to your project:

```bash
cp ~/.plaintext-scripts/build-conf.txt.template ./build-conf.txt
```

Add `build-conf.txt` to your `.gitignore` if it contains environment-specific values.

> **Der Dateiname ist nicht frei waehlbar.** `load_build_conf()` sucht ausschliesslich nach
> `build-conf.txt`. Bis zur Karte 961 stand hier `plaintext-build.cfg` — diesen Namen hat nie
> etwas gelesen; wer der Anleitung folgte, bekam `ERROR: build-conf.txt not found`.

### Configuration

`load_build_conf()` sucht **eine** Datei, in dieser Reihenfolge:

| Reihenfolge | Ort | Verwendung |
|----|-----|------------|
| 1 | `$PLAINTEXT_CONFIG_DIR/<projektname>/build-conf.txt` | die zentrale Konfiguration aus `plaintext-config` |
| 2 | `<projektverzeichnis>/build-conf.txt` | Projekte ausserhalb von `plaintext-config` |

Die erste gefundene Datei gewinnt; eine zweite wird nicht mehr gelesen.

> **Achtung:** die Werte aus der Datei werden per `export` gesetzt und ueberschreiben damit
> **gleichnamige Umgebungsvariablen**. Eine Variable vorher zu setzen wirkt also *nicht* als
> Uebersteuerung — hier stand frueher das Gegenteil (Karte 961). Ebenfalls entfernt:
> `PLAINTEXT_BUILD_CONFIG`, das im Code nirgends vorkommt (0 Treffer in `*.sh`).

#### Required settings

| Key | Description |
|-----|-------------|
| `IMAGE_NAME` | Docker image name |
| `WEBAPP_MODULE` | Maven webapp module name |
| `TUI_TITLE` | Title shown in the TUI menu |

#### Optional settings (with defaults)

| Key | Default | Description |
|-----|---------|-------------|
| `DEPLOY_PATH` | `/volume1/docker/${IMAGE_NAME}` | Remote deployment path on NAS |
| `DEPLOY_USER` | `mad` | SSH user for NAS |
| `NAS_HOST` | Auto-detected by hostname | NAS IP address |
| `REGISTRY_PORT` | `6666` | Docker registry port on NAS |
| `NAS_REMOTE_TEMP` | `/volume1/docker/temp` | Temp path for image transfer |
| `COMPOSE_FILE` | `docker-compose.yaml` | Docker Compose filename |
| `DB_NAME` | `${IMAGE_NAME}` | PostgreSQL database name |
| `DB_CONTAINER_PREFIX` | `${IMAGE_NAME}` | Database container name prefix |
| `DEV_PORT` | `1121` | DEV environment port |
| `PROD_PORT` | `1122` | PROD environment port |
| `MVN_RELEASE_DEPLOY` | `false` | Run `mvn deploy` instead of `mvn package` on release |
| `MIGRATION_GUARD_STRICT` | `false` | If `true`, block an automatic Blue-Green rollback even when the DB migration state can't be read (fail-closed). Default fails open (warn + proceed). |
| `MIGRATION_GUARD_DISABLE` | `false` | If `true`, disable the migration rollback guard entirely (old blind-rollback behaviour). Ops kill-switch. |

## Blue-Green rollback & DB migrations (Migration Guard)

A new (inactive) slot runs its Flyway migrations against the **shared** prod DB while booting —
**before** the external health check. If that check then fails, the automatic "instant rollback"
switches traffic back to the **old** container. Without a guard, the old code would then run against
the already-migrated (newer) schema.

The deploy logic therefore keeps a marker `${DEPLOY_PATH}/migver-<env>` (highest Flyway
`installed_rank`) written at the end of every **externally-confirmed** successful deploy. Before an
automatic rollback it compares the current DB rank against the marker:

- rank unchanged → rollback proceeds as before;
- rank increased (a migration ran this deploy) → **rollback is blocked**; the new (migrated) slot
  stays active (its code matches the schema) and the operator is told to either forward-fix or
  `restore_prod_db '<backup>'` + `switch_active <env> <old-slot>` manually.

Fail-open: if the marker is missing (first deploy after this change) or the DB is unreachable, the
old behaviour is kept (unless `MIGRATION_GUARD_STRICT=true`). `MIGRATION_GUARD_DISABLE=true` turns
the guard off entirely.

## Build Commands

| Command | Description |
|---------|-------------|
| `./build` | Interactive TUI menu |
| `./build 0` | Build + Run locally (no Docker) |
| `./build 1` | Maven build (SNAPSHOT) |
| `./build 2` | Major release (X.0.0) |
| `./build 3` | Minor release (x.X.0) |
| `./build 4` | Patch release (x.x.X) |
| `./build 5` | Minor release + deploy DEV (with health check) |
| `./build 6` | Deploy last release to PROD (with health check) |
| `./build 56` | Release + deploy DEV + PROD (multi-command) |
| `./build 8` | Lokal-Release: Release + Tag + Blue-Green **PROD direkt**, ohne CI (nur wo der Wrapper es verdrahtet, z.B. plaintext-app) |

### Lokal-Release (zweiter Weg neben CI/CD)

`./build local-release [1|2|3] [prod|dev-prod]` (plaintext-app: `./build 8`) macht den kompletten
Release von der Entwicklermaschine aus: Versionsschritt, Release-Commit, Git-Tag, Push, Build,
Jar/Image aufs NAS und Blue-Green-Deploy mit Healthcheck — ohne GitHub Actions. Die CI bleibt
der Standardweg (push/PR-merge auf master); der Lokal-Release ist fuer den Fall, dass die
Runner belegt sind oder ein Release bewusst von Hand ausgerollt werden soll.

Was ihn vom blossen `./build 56` unterscheidet:

- Der Release-Commit traegt `[skip-ci]` in der Betreffzeile — sonst startet der Push die
  CI-Pipeline, die parallel einen zweiten Release deployt. Die `skip-pruefung` der App-Pipeline
  fuehrt `Release version` als Automatik-Commit (kein Pushover-Alarm).
- Vorflug vor dem Tag: Branch = master, Arbeitsbaum sauber, origin nachgezogen (fast-forward),
  kein aktiver CI-Lauf auf master (`gh run list`), NAS erreichbar. Scheitert etwas, entsteht
  kein Tag.
- Fehlen die Reposilite-Zugangsdaten (server-id aus `distributionManagement` in
  `~/.m2/settings.xml`), wird nur gebaut (`mvn package`) statt veroeffentlicht — der Deploy
  haengt nicht davon ab.
- Scheitert der Push des Release-Commits, werden lokaler Commit und Tag zurueckgenommen.
- Tests: wie bei jedem lokalen Build standardmaessig `-DskipTests`; mit lokaler Test-DB
  `MVN_TEST_FLAG="-DskipITs -DexcludedGroups=quality-gate" ./build 8`.

Dieselben Sicherungen gelten fuer JEDEN lokalen Release-Lauf (`./build 3/4/5/56/7`, Erkennung
ueber `CI != true`): Vorflug vor dem Versionsschritt, `[skip-ci]` im Release-Commit, und
`deploy_to_dev`/`deploy_to_prod` sperren, solange ein CI-Rollout auf master laeuft. Ungespeicherte
Aenderungen bewusst mitnehmen (altes `git add -A`-Verhalten): `LOKAL_RELEASE_MIT_AENDERUNGEN=true`.

Trockenlauf ohne Seiteneffekte: `LOKAL_RELEASE_NUR_VORFLUG=true ./build 8`.
CI-Sperre bewusst uebergehen: `LOKAL_RELEASE_IGNORIERE_CI=true ./build 8`.
Sicherungen bewacht `./test-lokal-release.sh`.

## GitHub Actions

This repository provides a reusable workflow. Call it from your project:

```yaml
name: Deploy to NAS

on:
  workflow_dispatch:
    inputs:
      build-command:
        type: choice
        options: ['5', '6', '56']
        default: '56'

jobs:
  deploy:
    uses: Plaintext-Gmbh/plaintext-scripts/.github/workflows/maven-build-deploy.yaml@master
    with:
      build-command: ${{ inputs.build-command }}
      build-config: |
        IMAGE_NAME=myproject
        WEBAPP_MODULE=myproject-webapp
        TUI_TITLE=MY PROJECT BUILD SYSTEM
        DEPLOY_PATH=/volume1/docker/myproject
        DB_NAME=myproject
        DB_CONTAINER_PREFIX=myproject
        DEV_PORT=1121
        MVN_RELEASE_DEPLOY=true
    secrets:
      TWINGATE_SERVICE_KEY: ${{ secrets.TWINGATE_SERVICE_KEY }}
      MVN_DEPLOY_TOKEN: ${{ secrets.MVN_DEPLOY_TOKEN }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
```

## Voice-to-Claude

A voice-controlled interface for [Claude Code](https://claude.com/claude-code) on macOS. Speak your prompts, attach screenshots or clipboard content, and queue messages in batch mode.

### Prerequisites

| Dependency | Install |
|------------|---------|
| [whisper-cli](https://github.com/ggerganov/whisper.cpp) | `brew install whisper-cpp` |
| [SoX](http://sox.sourceforge.net/) (`rec` command) | `brew install sox` |
| Whisper model | Download `ggml-small.bin` to `~/.whisper-models/` |

### Usage

```bash
./voice           # German (default)
./voice en        # English
./voice fr        # French
```

### Controls

| Key | Action |
|-----|--------|
| `Enter` / `Space` | Start/stop recording |
| `Esc` | Quit |

### Voice Commands

Voice commands are triggered by **keywords at the beginning** of your spoken text. Keywords are case-insensitive and can be combined.

| Keyword | Effect |
|---------|--------|
| **Screenshot** | Takes a full-screen capture and sends it as a file reference to Claude Code |
| **Paste** | Prepends the current clipboard content (saved before recording) as a quoted block |
| **Screenshot Paste** | Combines both — clipboard content + screenshot in one prompt |
| **Batch** (alone) | Toggles **batch mode** on/off |

#### Screenshot

Say "Screenshot" followed by an optional instruction:

```
"Screenshot describe the layout"
→ Takes screenshot, sends: "describe the layout\n\nScreenshot: /tmp/voice_screenshot.png"

"Screenshot"
→ Takes screenshot, sends default: "Beschreibe was du auf dem Screenshot siehst."
```

Claude Code reads the saved image file via its `Read` tool.

#### Paste

Say "Paste" to include whatever was in your clipboard when recording started:

```
"Paste explain this code"
→ Sends: <eingefuegter-text>...</eingefuegter-text>\n\nexplain this code
```

#### Batch Mode

Batch mode lets you queue multiple prompts that are sent to Claude Code one-by-one, each waiting for the previous response to complete.

```
"Batch"                → Batch mode ON
"Fix the login bug"    → Queued as Batch #1
"Add unit tests"       → Queued as Batch #2
"Batch"                → Batch mode OFF (2 in queue)
```

The background monitor detects when Claude Code finishes (status changes from `Thinking…`/`Slithering…` etc. to idle) and automatically sends the next queued message.

### Idle Notification

A **Glass sound** plays whenever Claude Code finishes a response. Detection works by monitoring the Terminal window for Claude Code's status indicators:

- **Busy**: status line contains `ing…` (e.g. `Thinking…`, `Baking…`, `Slithering…`)
- **Idle**: busy indicator disappears, or completion marker `for Xs` appears

### Architecture

```
┌─────────────────────────┐     ┌──────────────────────┐
│   Voice Input Terminal  │     │  Claude Code Terminal │
│                         │     │                       │
│  rec → whisper → text   │────►│  (paste via osascript)│
│                         │     │                       │
│  Background monitor ◄───│─────│  (read terminal state)│
│  └─ idle? → Glass sound │     │                       │
│  └─ batch? → send next  │     │                       │
└─────────────────────────┘     └──────────────────────┘
```

- **Recording**: `rec` (SoX) captures 48kHz 16-bit mono WAV
- **Transcription**: `whisper-cli` with local `ggml-small.bin` model
- **Interaction**: `osascript` focuses the Claude terminal, `pbcopy`/Cmd+V pastes the prompt
- **Monitoring**: Background process reads Claude terminal content via `osascript`, detects state transitions
- **Batch queue**: File-based (`/tmp/voice_batch/*.txt`), monitor sends next on idle

### Temp Files

| File | Purpose |
|------|---------|
| `/tmp/voice_recording.wav` | Audio recording (deleted after transcription) |
| `/tmp/voice_screenshot.png` | Screenshot (overwritten each time) |
| `/tmp/voice_claude_busy` | Busy flag (exists while Claude is working) |
| `/tmp/voice_batch/` | Batch queue directory (cleaned up on exit) |

## Scripts

| File | Description |
|------|-------------|
| `tui-common.sh` | Terminal UI primitives (colors, box drawing, menu rendering) |
| `tui-build-logic.sh` | Build, release, deploy, and version management logic |
| `test-lokal-release.sh` | Guards for the local-release path (skip-ci subject, preflight order, rollback) |
| `tui-start-logic.sh` | Dev runner logic (start app, kill, logs, clean install) |
| `tui-modules-logic.sh` | Module toggle logic for multi-module projects |
| `start-postgres.sh` | Start PostgreSQL container (reads config from `build-conf.txt`) |
| `stop-postgres.sh` | Stop PostgreSQL container |
| `common-functions.sh` | Shared utility functions |
| `voice` | Voice-to-Claude interface (see above) |
| `build-conf.txt.template` | Configuration template for consumer projects |

## License

[Mozilla Public License 2.0](LICENSE)
