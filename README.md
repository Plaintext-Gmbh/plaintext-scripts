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
    git clone git@github.com:daniel-marthaler/plaintext-scripts.git "$SCRIPTS_DIR"
fi
source "$SCRIPTS_DIR/tui-common.sh"
source "$SCRIPTS_DIR/tui-build-logic.sh"

init_versions

# ... TUI menu and command dispatch (see plaintext-root for a full example)
```

### 2. Create `plaintext-build.cfg`

Copy the template and adjust to your project:

```bash
cp ~/.plaintext-scripts/plaintext-build.cfg.template ./plaintext-build.cfg
```

Add `plaintext-build.cfg` to your `.gitignore` — it contains environment-specific configuration.

### Configuration

Configuration is loaded with the following priority (highest wins):

| Priority | Source | Use case |
|----------|--------|----------|
| 1 | Individual environment variables | CI overrides, one-off changes |
| 2 | `PLAINTEXT_BUILD_CONFIG` env | GitHub Actions (full config as string) |
| 3 | `plaintext-build.cfg` file | Local development |
| 4 | `build-conf.txt` file | Legacy support |

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
    uses: daniel-marthaler/plaintext-scripts/.github/workflows/maven-build-deploy.yaml@master
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
| `tui-start-logic.sh` | Dev runner logic (start app, kill, logs, clean install) |
| `tui-modules-logic.sh` | Module toggle logic for multi-module projects |
| `start-postgres.sh` | Start PostgreSQL container (reads config from `build-conf.txt`) |
| `stop-postgres.sh` | Stop PostgreSQL container |
| `common-functions.sh` | Shared utility functions |
| `voice` | Voice-to-Claude interface (see above) |
| `plaintext-build.cfg.template` | Configuration template for consumer projects |

## License

[Mozilla Public License 2.0](LICENSE)
