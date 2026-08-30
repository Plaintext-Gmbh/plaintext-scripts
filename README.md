# plaintext-scripts

Shared build, release, deployment pipeline and developer tools for Maven-based projects with Docker and blue-green deployments to a NAS.

## Overview

This repository provides a reusable TUI-based build system and developer tools:

**Build & Deploy**
- **Maven builds** (SNAPSHOT and release)
- **Versionsschema MAJOR.MINOR.PATCH** — MINOR zaehlt Releases hoch; kein SemVer-Kompatibilitaetsversprechen (siehe „Versionierung")
- **Docker image builds** (Podman on macOS, Docker on Linux)
- **Blue-green deployments** to a Synology NAS with zero downtime
- **Health checks** with automatic rollback on failure
- **Database backups** (PostgreSQL) before production deployments
- **Interactive TUI menu** and CLI multi-command execution (e.g. `./build 56`)

**Developer Tools**
- **Voice-to-Claude** — Voice-controlled interaction with Claude Code (speech-to-text, screenshots, clipboard, batch mode)

## Installation

Das Repo wird **nicht automatisch geklont**. Die `build`-Wrapper der Projekte sourcen die
Bibliothek fest aus `$HOME/codeplain/plaintext-scripts` (so steht es in plaintext-app, -iot,
-schuetu, -guild und -root); die CI-Pipeline kopiert ihren Checkout an dieselbe Stelle
(Schritt „Install plaintext-scripts" in `ci-cd-pipeline.yaml`).

```bash
git clone git@github.com:Plaintext-Gmbh/plaintext-scripts.git ~/codeplain/plaintext-scripts
```

Aktualisieren:

```bash
git -C ~/codeplain/plaintext-scripts pull
```

> Bis zum Zustandsbericht 29.08.2026 stand hier `~/.plaintext-scripts` samt Auto-Clone beim
> ersten `./build` und einer Variable `PLAINTEXT_SCRIPTS_UPDATE` — beides gab es im Code nie
> (0 Treffer in `*.sh` und in den `build`-Wrappern der Projekte).

## Project Setup

### 1. `build`-Wrapper im Projekt-Root anlegen

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Bibliothek: fester Pfad, kein Auto-Clone (siehe Installation)
source "$HOME/codeplain/plaintext-scripts/tui-common.sh"
source "$HOME/codeplain/plaintext-scripts/tui-build-logic.sh"

init_versions

# ... TUI-Menue und Befehls-Dispatch (vollstaendiges Beispiel: plaintext-app/build)
```

### 2. `build-conf.txt` anlegen — in `plaintext-config`, nicht im Projekt

Die Konfiguration der Plaintext-Projekte liegt zentral im privaten Repo `plaintext-config`
unter `plaintext-config/<projektname>/build-conf.txt` (daneben `compose.yaml`,
`modules-conf.txt`, `deploy/`, `config/`). `load_build_conf()` leitet `<projektname>` aus dem
Verzeichnisnamen des Projekts ab (`basename`) und sucht zuerst dort — `$PLAINTEXT_CONFIG_DIR`,
Default `$HOME/codeplain/plaintext-config`; die CI-Pipeline checkt `plaintext-config` an genau
diese Stelle aus.

```bash
git clone git@github.com:Plaintext-Gmbh/plaintext-config.git ~/codeplain/plaintext-config
cp ~/codeplain/plaintext-scripts/build-conf.txt.template \
   ~/codeplain/plaintext-config/<projektname>/build-conf.txt
```

Eine `build-conf.txt` **im Projektverzeichnis** ist nur der Rueckfall fuer Projekte ausserhalb
von `plaintext-config`; sie gehoert dann in `.gitignore`, sobald sie umgebungsspezifische Werte
traegt.

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

### Versionierung — was die Nummern bedeuten

Das Schema ist `MAJOR.MINOR.PATCH`, aber **kein SemVer**: die Nummer sagt nichts ueber
Kompatibilitaet. Der Standard-Release (`./build 3`, `5`, `56` und jeder CI-Release auf
`master`) zaehlt **MINOR um eins hoch** — die Nummer ist ein Release-Zaehler (plaintext-app
steht bei 2.17xx.0, plaintext-root bei 1.6xx.0). `./build 4` zaehlt PATCH hoch, `./build 2`
MAJOR (setzt MINOR und PATCH auf 0); beides wird von Hand gewaehlt, nicht aus dem Inhalt
abgeleitet. Nach dem Release steht die POM auf `<gerade veroeffentlicht>-SNAPSHOT`;
hochgezaehlt wird erst beim naechsten Release (`compute_release_versions`, bewacht von
`test-versionsschritt.sh`). Pro Release entstehen ein Git-Tag `<version>` und — seit dem
Zustandsbericht 29.08.2026 — ein GitHub-Release mit generierten Notes (`gh release create
--generate-notes`, best-effort: ohne `gh` oder ohne Token nur ein Hinweis, nie ein Abbruch).

### Release-Lock — eine Nummer wird genau einmal vergeben

Bis zur Umstellung auf Woodpecker (30.08.2026) sorgte die GitHub-Concurrency-Gruppe
`deploy-<projekt>` dafuer, dass je Repo hoechstens ein Release-Lauf gleichzeitig faehrt.
**Woodpecker kennt keine Concurrency-Gruppen.** Ohne Ersatz rechnen zwei gleichzeitig
gestartete Laeufe aus derselben POM-Version dieselbe neue Nummer, bestehen beide die
Kollisionspruefung gegen das Release-Repo (die Nummer ist ja noch nirgends veroeffentlicht),
bauen beide — und erst der `git push` des zweiten wird abgelehnt. Bei plaintext-root sind das
24 Module und rund 20 Minuten Build fuer nichts.

Der Ersatz ist ein **Release-Lock auf dem NAS**, derselbe Mechanismus wie fuer
`staging`/`int`/`prod` (atomares `mkdir` ueber SSH, Besitzer-Token mit Zeitstempel,
`DEPLOY_LOCK_WAIT` = 1800 s Wartezeit, `DEPLOY_LOCK_STALE` = 3600 s fuer verwaiste Locks).
Er liegt auf dem NAS, weil sich dort — und nur dort — **alle** Laeufe treffen: Woodpecker,
GitHub Actions, `./build 3` auf dem Mac, Nacht-Runner. Der Name ist
`.deploy-lock-release-<projekt>` unter `DEPLOY_PATH`, also einer je Repo: root und app
blockieren sich nicht gegenseitig.

- **Gesperrt ist genau** "Nummer rechnen → Nummer beanspruchen": nachziehen, rechnen,
  Kollisionspruefung, `mvn versions:set`, Commit, Tag, Push von Commit und Tag
  (`release_nummer_beanspruchen`). Danach wird sofort freigegeben — **der Build laeuft NICHT
  unter dem Lock** (`do_release_bauen_und_veroeffentlichen`). Sonst haette ein wartender Lauf
  bei root die 1800 s Wartezeit gerissen, und aus der geloesten Race waere ein neuer
  Fehlerfall geworden.
- **Nach dem Warten wird der Stand neu gezogen** (`release_stand_nachziehen`: `git fetch`,
  fast-forward, `init_versions`). `CURRENT_VERSION` wird beim Start des Wrappers gesetzt; wer
  eine halbe Stunde gewartet hat, wuerde sonst dieselbe Nummer noch einmal rechnen — ein Lock
  allein verschiebt die Race nur.
- **Freigabe auf jedem Pfad**: regulaere Fehler ueber das Muster
  `nehmen → gesperrter Abschnitt → Rueckgabewert → freigeben` (wie
  `deploy_to_prod`/`deploy_to_prod_gesperrt`), harte Abbrueche (Ctrl-C, `kill`) ueber einen
  INT/TERM-Trap. Ein `kill -9` faengt `DEPLOY_LOCK_STALE` ab.
- **Ohne NAS kein Release.** Der Lock haengt an SSH zum NAS; fuer `staging`/`int`/`prod` ist
  das laengst Voraussetzung, in der CI richtet der Deploy-Job SSH ohnehin ein. Ein reiner
  `release-only`-Lauf (plaintext-root) kam bisher ohne aus und scheitert jetzt mit einer
  Meldung, die den Grund nennt. Bewusster Ausweg, laut und nur von Hand:
  `RELEASE_LOCK_OHNE_NAS=true ./build 3` — dann laeuft der Release ohne Lock, und zwei
  gleichzeitige Laeufe koennen wieder dieselbe Nummer rechnen. Ein stiller Rueckfall waere
  keine Loesung: er sieht aus wie ein Schutz und ist keiner.

Nachgestellt (echte Git-Repos, echtes `mkdir`, `ssh` als Attrappe, Lock in einem
Wegwerf-Verzeichnis): `./test-release-lock.sh` — Race mit und ohne Lock, verwaister Lock,
fremder frischer Lock, Fehlerfall, SIGTERM, NAS-Ausfall.

### Lokal-Release (zweiter Weg neben CI/CD)

`./build local-release [1|2|3] [prod|dev-prod]` (plaintext-app: `./build 8`) macht den kompletten
Release von der Entwicklermaschine aus: Versionsschritt, Release-Commit, Git-Tag, Push, Build,
Jar/Image aufs NAS und Blue-Green-Deploy mit Healthcheck — ohne GitHub Actions. Die CI bleibt
der Standardweg (push/PR-merge auf master); der Lokal-Release ist fuer den Fall, dass die
Runner belegt sind oder ein Release bewusst von Hand ausgerollt werden soll.

Was ihn vom blossen `./build 56` unterscheidet:

- Der Release-Commit traegt das native `[skip ci]` in der Betreffzeile — sonst startet der Push
  die CI-Pipeline, die parallel einen zweiten Release deployt. Seit dem Zustandsbericht
  29.08.2026 gilt das fuer JEDEN Release-Commit, auch in der CI (vorher `[skip-ci]` mit
  Bindestrich, das GitHub nicht kennt: es erzeugte Laeufe, die auf einem NAS-Runner nur
  uebersprungen oder per Concurrency abgebrochen wurden). Die `skip-pruefung` der App-Pipeline
  fuehrt `Release version` zusaetzlich als Automatik-Commit (kein Pushover-Alarm).
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
ueber `CI != true`): Vorflug vor dem Versionsschritt, `[skip ci]` im Release-Commit, und
`deploy_to_dev`/`deploy_to_prod` sperren, solange ein CI-Rollout auf master laeuft. Ungespeicherte
Aenderungen bewusst mitnehmen (altes `git add -A`-Verhalten): `LOKAL_RELEASE_MIT_AENDERUNGEN=true`.

Trockenlauf ohne Seiteneffekte: `LOKAL_RELEASE_NUR_VORFLUG=true ./build 8`.
CI-Sperre bewusst uebergehen: `LOKAL_RELEASE_IGNORIERE_CI=true ./build 8`.
Sicherungen bewacht `./test-lokal-release.sh`.

## GitHub Actions

### Welcher CI-Motor faehrt? (`.ci-engine`)

Seit dem 30.08.2026 kann ein Repo seine Pipeline wahlweise von GitHub Actions oder von
Woodpecker (`https://ci.plaintext.ch`) fahren lassen — inklusive Release und
Blue-Green-Deploy. Die Entscheidung steht als **ein Wort** in der Datei `.ci-engine` im
Repo-Root: `github` oder `woodpecker`. **Fehlt die Datei, gilt `github`** — ein Repo ohne
Datei aendert sich also nicht.

Durchgesetzt wird das vom Job **`ci-motor`**, dem ersten Job dieser Pipeline: er laeuft auf
`ubuntu-latest`, checkt per sparse checkout **nur** diese eine Datei aus und liefert den
Output `zustaendig`. `ci`, `sonar` und `deploy` haengen daran; `verify-dev` und `verify-prod`
folgen ueber `needs: deploy`. `namespace-lint` bleibt **bewusst** ungesperrt — die
Woodpecker-Seite hat dafuer keine Entsprechung, und der Job kostet keinen NAS-Runner.

Warum der Waechter hier steht und nicht in den vier Aufrufern: so ist das Umschalten eines
Repos genau ein Commit (die `.ci-engine`-Datei), ohne Eingriff in `ci-cd.yaml`.

**Auch `schedule` folgt der Datei — seit dem 30.08.2026.** Bis dahin gab es eine Ausnahme:
geplante Laeufe (Nightly und woechentliche Voll-Analyse) blieben immer bei GitHub Actions,
weil der OWASP-CVE-Scan einen persistenten NVD-Bestand braucht und der Woodpecker-Agent
keinen hatte. Diese Begruendung ist entfallen: die Repos haben jetzt
`.woodpecker/analyse.yml`, dessen CVE-Step das vorhandene Volume `github-runners_odc-cache`
selbst einhaengt (`trusted.volumes = true` am Repo) und darin je Repo ein eigenes
Unterverzeichnis fuehrt. Die Ausnahme MUSSTE weg und war nicht bloss ueberfluessig: sonst
bewerteten zwei Systeme dasselbe Repo und committeten beide `quality/quality-gate.properties`
auf `master` zurueck. Ein Repo im Woodpecker-Modus braucht seine Crons jetzt **dort**
(`nightly`, `wochenanalyse`) — die GitHub-`schedule`-Eintraege der Aufrufer laufen zwar
weiter, werden aber vom `ci-motor` abgefangen und tun nichts.

Enthaelt `.ci-engine` etwas anderes als die beiden Woerter (auch: leere Datei), bricht der
Job **rot** ab statt zu raten. Beide Waechter lesen dieselbe Datei und steigen bei allem aus,
was nicht ihr eigener Name ist — ein Tippfehler wuerde sonst *beide* Systeme stilllegen, und
zwar lautlos mit lauter gruenen Haekchen.

Bedienung, Secret-Liste und die nicht portierten Teile: `docs/CI-UMSCHALTEN.md` im jeweiligen
Repo (Vorlage und Pilot: `plaintext-iot`).

### CI/CD-Pipeline (`ci-cd-pipeline.yaml`)

Der zentrale reusable Workflow ist `.github/workflows/ci-cd-pipeline.yaml` (bis zum
Zustandsbericht 29.08.2026 stand hier ein nicht existierendes `maven-build-deploy.yaml` mit
ebenso nicht existierenden Inputs). Jobs: `ci-motor` (Waechter, siehe oben) →
`namespace-lint` (ubuntu-latest) → `ci` (Build+Test,
nur ci-only/Sonar) → `sonar` → `deploy` → `verify-dev` / `verify-prod`. Das Ereignis des
Aufrufers bestimmt das Ziel; die Build-Konfiguration kommt aus `plaintext-config`, nicht aus
dem Aufruf. Gekuerztes Beispiel nach `plaintext-app/.github/workflows/ci-cd.yaml`:

```yaml
name: Build And Deploy

on:
  workflow_dispatch:
  schedule:
    - cron: '0 1 * * *'    # Nightly ci-only — hier laeuft seit Paket S auch das Quality-Gate mit
    - cron: '0 4 * * 1'    # Wochenlauf mit Sonar/OWASP (je Repo gestaffelt, Karte 889)
  push:
    branches: ['**']
  pull_request:
    branches: [master]

permissions:
  contents: write
  packages: write

jobs:
  pipeline:
    uses: Plaintext-Gmbh/plaintext-scripts/.github/workflows/ci-cd-pipeline.yaml@master
    with:
      deploy-target: >-
        ${{ github.event_name == 'schedule' && 'ci-only'
         || github.event_name == 'pull_request' && 'ci-only'
         || (github.ref == 'refs/heads/master' && 'release-all' || 'snapshot-dev') }}
      project-name: plaintext-app
      database-name: plaintext
      dev-url: 'http://192.168.1.224:1111'
      prod-url: 'http://192.168.1.224:1112'
      sonar-enabled: ${{ (github.event_name == 'schedule' && !endsWith(github.event.schedule, '* * *')) || github.event_name == 'workflow_dispatch' }}
      quality-analysis: ${{ (github.event_name == 'schedule' && !endsWith(github.event.schedule, '* * *')) || github.event_name == 'workflow_dispatch' }}
      runner: '["self-hosted", "nas"]'
      postgres-port: '5436'
    secrets:
      TWINGATE_SERVICE_KEY: ${{ secrets.TWINGATE_SERVICE_KEY }}
      MVN_DEPLOY_TOKEN: ${{ secrets.MVN_DEPLOY_TOKEN }}
      MAVEN_NAS_TOKEN: ${{ secrets.MAVEN_NAS_TOKEN }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
      NVD_API_KEY: ${{ secrets.NVD_API_KEY }}
      PUSHOVER_APP_TOKEN: ${{ secrets.PUSHOVER_APP_TOKEN }}
      PUSHOVER_USER_KEY: ${{ secrets.PUSHOVER_USER_KEY }}
```

Alle Inputs (`deploy-target`, `project-name`, `database-name`, `java-version`, `dev-url`,
`prod-url`, `playwright-enabled`, `integration-tests-enabled`, `sonar-enabled`,
`quality-analysis`, `sonar-url`, `runner`, `verify-prod-runner`, `postgres-port`,
`scripts-ref`) und Secrets sind im `workflow_call`-Block der Pipeline beschrieben.
`deploy-target`: `ci-only`, `snapshot-dev`, `release-dev`, `release-all`, `release-only`,
`prod-single`.

#### `verify-prod` von aussen (`verify-prod-runner`, Massnahme 3 Rest, 29.08.2026)

`verify-dev`/`verify-prod` pollen `<url>/nosec/version` und fahren optional E2E-Tests. Beide
liefen bisher auf dem NAS-Runner — zwangslaeufig, denn **alle vier Aufrufer geben LAN-Adressen**
(`http://192.168.1.224:<port>`) als `dev-url` UND `prod-url`. Der Twingate-Schritt fuer
GitHub-Runner ist in der sichtbaren Historie nie gelaufen (alle Aufrufer `self-hosted`; root nimmt
`ubuntu-latest` nur fuer `pull_request`, dort ist `deploy-target=ci-only` und beide Verify-Jobs
werden uebersprungen).

Fuer PROD gibt es aber oeffentliche Hostnamen — und `/nosec/version` liefert dort dieselbe
Nummer wie im LAN (vom Mac geprueft, DNS zeigt auf Cloudflare 188.114.x, 29.08.2026):

| App | LAN (`prod-url` heute) | oeffentlich | `/nosec/version` |
|-----|------------------------|-------------|------------------|
| plaintext-app | `http://192.168.1.224:1112` | `https://app.plaintext.ch` | 2.1717.0 = 2.1717.0 |
| plaintext-guild | `http://192.168.1.224:1152` | `https://guild.plaintext.ch`, `https://app.guild42.ch` | 1.433.0 = 1.433.0 |
| plaintext-iot | `http://192.168.1.224:1122` | `https://iot.plaintext.ch` | 1.342.0 = 1.342.0 |
| plaintext-schuetu | `http://192.168.1.224:1132` | `https://schuelerturnier.plaintext.ch` | 1.584.0 = 1.584.0 |

DEV hat keinen oeffentlichen Hostnamen; `verify-dev` bleibt deshalb auf dem NAS-Runner.

Entscheidung: `verify-prod` wird **nicht pauschal** auf `ubuntu-latest` gestellt — die Pipeline
wird `@master` konsumiert, ein harter Wechsel haette beim naechsten Release aller vier Apps gegen
die LAN-Adresse gepollt. Stattdessen der Input `verify-prod-runner` (JSON-Array, leer = wie
`runner`). Ein Aufrufer stellt um, indem er **beides** setzt:

```yaml
      prod-url: 'https://app.plaintext.ch'
      verify-prod-runner: '["ubuntu-latest"]'
```

Auf einem GitHub-Runner prueft der Job zuerst, dass `prod-url` keine LAN-Adresse ist, und bricht
sonst sofort mit `::error` ab — statt 7,5 Minuten ins Leere zu pollen und dann nur zu warnen.
Der Twingate-Schritt ist aus `verify-prod` entfernt (der GitHub-Runner-Pfad heisst dort
"oeffentliche URL", nicht "LAN ueber Tunnel"); in `verify-dev` bleibt er, ist aber als
unverifiziert markiert. Gewinn der Umstellung: ein NAS-Runner weniger belegt in der Phase nach
dem Blue-Green-Deploy, und die Verifikation sieht die App so, wie die Nutzer sie sehen (ein
kaputter Cloudflare-Tunnel faellt im LAN nicht auf).

Die Release-Commits der Pipeline (`Release version …`, `Prepare next development iteration …`,
`chore(quality): Quality-Gate-Status …`) tragen das **native `[skip ci]`** — GitHub erzeugt fuer
diese Pushes keinen Lauf. Die `skip-pruefung` in den App-Repos liest weiterhin `[skip-ci]`
(Bindestrich) fuer von Hand markierte Commits; sie sollte kuenftig beide Formen kennen.

### Reusable Workflows fuer die App-Repos (Paket S)

Drei Workflows lagen viermal kopiert in app, iot, schuetu und guild. Sie liegen jetzt hier
als `workflow_call`; ein App-Repo behaelt nur den Aufrufer mit Zeitplan und seinen Werten.
Gemeinsame Regeln:

- `github.repository`, `github.token`, `GITHUB_SHA` und ein `actions/checkout` ohne
  `repository:` gehoeren im aufgerufenen Workflow dem **Aufrufer** — gearbeitet wird also im
  App-Repo.
- Die `permissions` muss der Aufrufer gewaehren; der aufgerufene Workflow kann nie mehr haben.
- `concurrency` steht im aufgerufenen Workflow auf Job-Ebene; der Aufrufer setzt seine
  Workflow-Gruppe zusaetzlich (wie bisher).
- Secrets explizit durchreichen (kein `secrets: inherit`, Karte 717).

#### `root-autobump.yaml` — root-Version per PR nachziehen (Karte 322)

| Input | Pflicht | Default | Bedeutung |
|-------|---------|---------|-----------|
| `pgport` | ja | — | Host-Port des Test-Postgres; Schema ci-Port + 200 (app 5636, iot 5635, schuetu 5637, guild 5639) |
| `db-name` | ja | — | Test-DB (`plaintext`, `plaintext_iot`, `plaintext_schuetu`, `plaintext_guild`) |
| `java-version` | nein | `25` | JDK des Verify-Builds |
| `dry-run` | nein | `false` | nur pruefen und bauen, kein PR |
| `scripts-ref` | nein | `master` | Ref von plaintext-scripts fuer `ci/root-autobump.sh` |
| `bump-branch` | nein | `chore/root-autobump` | Branch des Bump-PR |

Secrets: `MVN_DEPLOY_TOKEN` (Pflicht), `MAVEN_NAS_TOKEN` (Pflicht), `AUTOBUMP_TOKEN`
(optional, sonst `github.token` mit Freigabepflicht), `PUSHOVER_APP_TOKEN`,
`PUSHOVER_USER_KEY` (optional). Runner: `[self-hosted, nas]` (maven.plaintext.ch ist LAN-only).

```yaml
name: Root Auto-Bump

on:
  schedule:
    - cron: '15 23 * * *'   # Fensteranfaenge, nicht Uhrzeiten (Karte 792)
    - cron: '15 7 * * *'
  workflow_dispatch:
    inputs:
      dry-run:
        description: 'Nur pruefen und bauen, keinen PR erstellen'
        type: boolean
        default: false

permissions:
  contents: write
  pull-requests: write
  actions: read

concurrency:
  group: root-autobump-${{ github.repository }}
  cancel-in-progress: false

jobs:
  autobump:
    uses: Plaintext-Gmbh/plaintext-scripts/.github/workflows/root-autobump.yaml@master
    with:
      pgport: '5636'
      db-name: plaintext
      dry-run: ${{ inputs.dry-run || false }}
    secrets:
      MVN_DEPLOY_TOKEN: ${{ secrets.MVN_DEPLOY_TOKEN }}
      MAVEN_NAS_TOKEN: ${{ secrets.MAVEN_NAS_TOKEN }}
      AUTOBUMP_TOKEN: ${{ secrets.AUTOBUMP_TOKEN }}
      PUSHOVER_APP_TOKEN: ${{ secrets.PUSHOVER_APP_TOKEN }}
      PUSHOVER_USER_KEY: ${{ secrets.PUSHOVER_USER_KEY }}
```

#### `publish-root-pin.yaml` — benutzte root-Version nach plaintext-mvn melden (Karte 942)

| Input | Pflicht | Default | Bedeutung |
|-------|---------|---------|-----------|
| `heartbeat-days` | nein | `7` | nach so vielen Tagen auch ohne Aenderung neu schreiben |
| `mvn-repo` | nein | `Plaintext-Gmbh/plaintext-mvn` | Ziel-Repo |
| `pin-branch` | nein | `pins` | Datenbranch drueben (nicht master) |

Secrets: `AUTOBUMP_TOKEN` (Pflicht), `PUSHOVER_APP_TOKEN`, `PUSHOVER_USER_KEY` (optional).
Runner: ubuntu-latest. Der Wochentag im Cron bleibt je Repo verschieden (app Mo, iot Di,
schuetu Mi, guild Do).

```yaml
name: root-Pin veroeffentlichen

on:
  push:
    branches: [master]
    paths: ['pom.xml']
  schedule:
    - cron: '23 4 * * 1'
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: publish-root-pin-${{ github.repository }}
  cancel-in-progress: false

jobs:
  pin:
    uses: Plaintext-Gmbh/plaintext-scripts/.github/workflows/publish-root-pin.yaml@master
    secrets:
      AUTOBUMP_TOKEN: ${{ secrets.AUTOBUMP_TOKEN }}
      PUSHOVER_APP_TOKEN: ${{ secrets.PUSHOVER_APP_TOKEN }}
      PUSHOVER_USER_KEY: ${{ secrets.PUSHOVER_USER_KEY }}
```

#### `housekeeping.yml` — alte Workflow-Laeufe loeschen

Input `task` (Pflicht): `deleteLogs5` (je Workflow die letzten 5 behalten) oder `deleteLogAll`.
Keine Secrets; `github.token` des Aufrufers braucht `actions: write`. Der Workflow laeuft in
plaintext-scripts selbst weiterhin per `workflow_dispatch`.

```yaml
name: housekeeping

on:
  workflow_dispatch:
    inputs:
      task:
        description: 'Task to run'
        required: true
        default: 'deleteLogs5'
        type: choice
        options: [deleteLogs5, deleteLogAll]

permissions:
  actions: write
  contents: read

jobs:
  run:
    uses: Plaintext-Gmbh/plaintext-scripts/.github/workflows/housekeeping.yml@master
    with:
      task: ${{ inputs.task }}
```

### `ci/root-autobump.sh` — kanonisches Bump-Skript

Das Skript hinter dem Auto-Bump liegt nur noch hier (`ci/root-autobump.sh`, BSD-/GNU-tauglich:
kein `sed -i`). Der reusable Workflow ruft es aus seinem Checkout von plaintext-scripts auf;
ein App-Repo braucht keine Kopie mehr. Wer es lokal aufrufen will (`detect` zeigt den
Rueckstand, `apply` setzt die pom.xml), legt hoechstens einen duennen Wrapper an — dasselbe
Muster wie beim `build`-Wrapper:

```bash
#!/usr/bin/env bash
# .github/scripts/root-autobump.sh — Wrapper, die Logik liegt in plaintext-scripts/ci/root-autobump.sh
exec "${PLAINTEXT_SCRIPTS_DIR:-$HOME/codeplain/plaintext-scripts}/ci/root-autobump.sh" "$@"
```

Aufruf: `root-autobump.sh detect` (stdout + `GITHUB_OUTPUT`: current/parent/latest/behind/
vollstaendig/fehlend/bump) bzw. `root-autobump.sh apply [version]`. Umgebung: `POM_FILE`
(Default `pom.xml`), `ROOT_MAVEN_REPO` (Default `https://maven.plaintext.ch/releases`),
`BUMP_IGNORIERE_MODULE` (s. u.). Ein Interfaces-Pin
`<plaintext-root-interfaces.version>${plaintext-root.version}</...>` gilt als **gekoppelt**
(folgt dem Bump von selbst); nur ein abweichendes Literal wird als „entkoppelt" gemeldet und
nicht angefasst.

**Nur vollstaendige Releases (Massnahme 4, 29.08.2026 — „halbes Release sichtbar").**
`mvn deploy` von root laedt 24 Module ueber rund 15 Minuten hoch; die `<release>`-Angabe der
Parent-Metadata steht aber schon nach dem Parent. Ein Bump in diesem Fenster sah ein halbes
Release (Verify rot, unaufloesbarer PR). `deployAtEnd=true` im root-POM war der erste Versuch
und ist gescheitert (zwei Deploy-Ausfuehrungen GitHub Packages + Reposilite → doppelter Upload
→ 409). Deshalb prueft `detect` jetzt das LESEN: Parent-POM der Kandidatenversion laden, jedes
`<module>` (oberste Ebene, ohne Kommentare und `<profiles>`) per HTTP HEAD auf
`…/ch/plaintext/<modul>/<v>/<modul>-<v>.pom`. Fehlt eines: `vollstaendig=false`,
`fehlend=<Liste>`, `bump=false`, Meldung „Release `<v>` noch unvollstaendig (fehlt: …),
naechster Lauf", **Exit 0** — kein Fehler, der Cron kommt wieder. `apply` mit einer
unvollstaendigen Version wird verweigert (Exit 1). Nicht pruefbar (5xx, Netz) zaehlt wie
fehlend. Bleibt dieselbe Meldung ueber Stunden, ist es kein Zeitfenster: ein Modul, das
absichtlich nie deployt wird (`maven.deploy.skip`), nimmt `BUMP_IGNORIERE_MODULE="a b"` aus der
Pruefung. Erst NACH der Vollstaendigkeit prueft das Skript, ob jedes von der pom benoetigte
Artefakt in der Version existiert — dort ist ein Fehlen kein Zeitfenster mehr, sondern ein
umbenanntes/entferntes Modul, und der Lauf bricht hart ab.

Die Funktionen liegen in `ci/reposilite-release.sh` (reine Funktionen, bash 3.2-tauglich,
`file://`-Repos fuer Tests). Dieselbe Bibliothek nutzt `tui-build-logic.sh` als
**Selbstkontrolle des Release-Jobs**: `release_vollstaendig_pruefen <version>` laeuft in
`do_release` direkt nach `mvn clean deploy` (nur bei `MVN_RELEASE_DEPLOY=true` und
`<module>` in der pom), bildet `<modul>/pom.xml` auf die echte artifactId ab und meldet
„Release `<v>` vollstaendig im Release-Repo (24 Module)" bzw. rot „UNVOLLSTAENDIG — es fehlt:
…" plus `::warning`-Annotation in der CI. Nie fatal: Tag und Release-Commit sind da
draussen, ein Abbruch liesse nur den SNAPSHOT-Commit aus. Tests: `./test-root-autobump.sh`.

### Selbstpruefung dieses Repos

| Workflow | Prueft | Runner |
|----------|--------|--------|
| `namespace-lint.yaml` | keine funktionale Referenz auf den alten Namespace (`quality/namespace-lint.sh`) | ubuntu-latest |
| `shellcheck.yaml` | `bash -n` + `shellcheck -S warning` ueber jede Datei mit Bash-Shebang (`quality/shellcheck.sh`) | ubuntu-latest |
| `quality-dashboard.yaml` | woechentliche Uebersicht aller Projekte auf GitHub Pages | self-hosted |

Lokal: `./quality/shellcheck.sh` (mit `brew install shellcheck`; ohne shellcheck nur
`bash -n`) und `./quality/namespace-lint.sh .`; Workflows mit `actionlint`
(`.github/actionlint.yaml` kennt die NAS-Runner-Labels). Die Testskripte (`test-*.sh`, ohne
Netz, ohne Attrappen fuer curl — Repo-Attrappen liegen als `file://` im Dateisystem):
`./test-versionsschritt.sh`, `./test-release-reihenfolge.sh`, `./test-lokal-release.sh`,
`./test-release-lock.sh`, `./test-root-autobump.sh`, `./test-backup-prod-db.sh tui-build-logic.sh`,
`./test-pushover.sh`, `./test-pushover-eskalation.sh`.

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
| `test-lokal-release.sh` | Guards for the release path (native `[skip ci]` subject, preflight order, rollback, release notes) |
| `test-root-autobump.sh` | Vollstaendigkeitspruefung (Massnahme 4): halbes Release, komplett, Parent fehlt, Ausnahmen, Selbstkontrolle |
| `test-release-lock.sh` | Nachgestellte Race der Versionsvergabe: zwei parallele Laeufe mit und ohne Release-Lock, verwaister Lock, Fehlerfall, SIGTERM, NAS-Ausfall |
| `ci/root-autobump.sh` | Kanonisches Auto-Bump-Skript fuer die App-Repos (siehe oben) |
| `ci/reposilite-release.sh` | Bibliothek: ist ein Multi-Modul-Release im Maven-Repo vollstaendig? (Auto-Bump + Release-Selbstkontrolle) |
| `quality/shellcheck.sh` | `bash -n` + shellcheck ueber alle Bash-Skripte (CI: `shellcheck.yaml`) |
| `quality/namespace-lint.sh` | Leitplanke gegen den alten Namespace (CI: `namespace-lint.yaml` und Pipeline-Job) |
| `tui-start-logic.sh` | Dev runner logic (start app, kill, logs, clean install) |
| `tui-modules-logic.sh` | Module toggle logic for multi-module projects |
| `start-postgres.sh` | Start PostgreSQL container (reads config from `build-conf.txt`) |
| `stop-postgres.sh` | Stop PostgreSQL container |
| `common-functions.sh` | Shared utility functions |
| `voice` | Voice-to-Claude interface (see above) |
| `build-conf.txt.template` | Configuration template for consumer projects |

## License

[Mozilla Public License 2.0](LICENSE)
