# Build- & Deploy-Beschleunigung (alle Plaintext-Apps)

Ziel: Build/Deploy deutlich schneller; Idee des Users: Image vom Jar trennen (nur Jar ins
gemountete Volume deployen) bzw. nur geänderte Module austauschen. Gilt zentral für alle Apps
(app, root, iot, schuetu, fwtool) über `plaintext-scripts` (geteilter Workflow + `tui-build-logic.sh`)
und `plaintext-dockercompose` (gitops, blue-green).

## Ist-Zustand (Befund)

- CI-Runner läuft **auf dem NAS** (`runs-on: [self-hosted, nas]`) → **kein Netzwerk-Transfer**;
  der Flaschenhals ist der **Build**, nicht das Übertragen.
- Pro `release-all` (`./build 56`):
  1. `ci`-Job: `mvn clean install -DskipITs` (alle Module + Unit-Tests) — **Vollbuild #1**
  2. `deploy`-Job `./build 56` → `do_release`:
     - `mvn versions:set` (Release-Version) + git commit/tag
     - `mvn clean deploy -DskipTests` — **Vollbuild #2**
     - `docker build` (Image mit eingebackenem Jar)
     - `push_to_registry`: `docker save | gzip | ssh DEPLOY_SERVER | docker load` — **ganzes Image**
     - `mvn versions:set` next-snapshot + commit/push
     - `deploy_to_dev` + `deploy_to_prod`: blue-green (Slot neu mit Image-Tag, Healthcheck, nginx-Switch)
- Maven-Build-Cache: vorhanden aber **AUS** (`.mvn/maven-build-cache-config.xml` → `enabled=false`,
  keine `.mvn/extensions.xml`). Zudem Glob unvollständig (s. M2-Falle).
- Compose nutzt `image: <app>:<version>` → jeder Deploy bumpt den Tag → gitops-Commit + recreate.

## Maßnahmen

### M1 — KONKRETE UMSETZUNG (zuerst, lt. User)

**Ist:** `ci`-Job `mvn clean install -DskipITs` (Compile+UnitTests, SNAPSHOT) UND separater
`deploy`-Job `./build` → `do_release`/`do_build_snapshot` mit `mvn clean deploy/package -DskipTests`
(Compile+Package, RELEASE). Beide kompilieren alle Module → Doppel-Compile in zwei Jobs/Workspaces.

**Soll (build once):** Der `deploy`-Job wird die EINZIGE Build-Quelle (Compile+UnitTests+Package+Deploy);
der separate `ci`-Build entfällt für Deploy-Targets.

Edits in `plaintext-scripts/.github/workflows/ci-cd-pipeline.yaml`:
- `ci`-Job: `if: inputs.deploy-target == 'ci-only' || inputs.sonar-enabled` (läuft nur noch für PRs +
  Sonar-Schedule; `sonar`-Job behält `needs: ci`).
- `deploy`-Job: `needs: ci` ENTFERNEN; Postgres-Start-Step + DB-Env (`SPRING_DATASOURCE_*`) ergänzen
  (eigener Container-Name/Port, z.B. `ci-postgres-${PGPORT}-deploy` auf `PGPORT+100`, um Kollision mit
  dem ci-Job bei Schedule zu vermeiden). `verify-*` behalten `needs: deploy`.
**WICHTIG — lokale Builds NICHT brechen:** Das `-DskipTests` im Release-Build ist bewusst (lokale
`./build`-Releases / Nacht-Runner laufen ohne Test-DB). „Build once mit Tests" darf NUR die CI betreffen.
→ Deshalb NICHT einfach `-DskipTests` in `do_release` entfernen.

Sauberer Ansatz (CI baut einmal MIT Tests, `./build` baut dann nicht nochmal):
- `tui-build-logic.sh` `do_release`/`do_build_snapshot`: wenn `CI_PREBUILT=true` (von der CI gesetzt),
  den internen `mvn clean deploy/package`-Schritt ÜBERSPRINGEN (target/ ist bereits gebaut) — nur
  Versionierung/git/docker/push/deploy. Lokal (ohne `CI_PREBUILT`) bleibt alles wie bisher (skipTests).
- CI deploy-Job-Ablauf: (release) `mvn versions:set <release>` → `mvn clean deploy -B -DskipITs` (EIN
  Build mit UnitTests, publiziert Artefakte) → `CI_PREBUILT=true ./build <target>` (macht git/tag/docker/
  push/blue-green ohne erneuten mvn-Build) → `mvn versions:set <next-snapshot>` + commit/push.
  Alternativ die Versionierung als eigene `./build prepare-release`/`./build finish-release`-Kommandos
  kapseln, damit die Logik an einer Stelle bleibt.
- Tests im CI-Build brauchen DB → Postgres-Step + `SPRING_DATASOURCE_*` im deploy-Job (eigener
  Container-Name/Port gegen Schedule-Kollision, s.o.).

**Gemeinsame Fälle nach M1 (je EIN Build):** PR→ci-only (nur ci/test); Branch-Push→snapshot-dev (nur
deploy, mit Tests); master→release-all (nur deploy, mit Tests+Release+dev+prod). Schedule→ci(sonar)+deploy.

**Repo-Hinweis:** App-`ci-cd.yaml` nutzt `uses: Plaintext-Gmbh/plaintext-scripts@master`, der
deploy-Job klont aber `daniel-marthaler/plaintext-scripts` für `./build`. VOR Umsetzung klären, welches
Remote/Fork maßgeblich ist (beide ggf. synchron halten). Lokal: `/home/mad/codeplain/plaintext-scripts`.

**Validierung (ohne andere Apps zu brechen):** plaintext-scripts-Branch `feat/build-once`; in einem
plaintext-app-Testbranch `ci-cd.yaml` temporär auf `@feat/build-once` zeigen; Push (→ snapshot-dev) →
ein einziger Build + Deploy auf DEV beobachten; bei grün plaintext-scripts→master mergen + App zurück
auf `@master`. Dauer vorher/nachher per `gh run view --json` (bzw. später Build-Stats-Webapp) messen.

### M1 — Hintergrund (Vollbuild #2 eliminieren)
Heute: `ci` baut+testet (snapshot-Version), `deploy` baut nochmal (release-Version). Weil die
Version sich ändert, sind die `ci`-Artefakte nicht wiederverwendbar → der zweite Build ist „nötig".
**Fix:** Versionierung VOR den (einzigen) Build ziehen und ci+deploy in einen Job zusammenlegen:
1. (nur bei release) `mvn versions:set <release>` + commit/tag
2. **ein** `mvn clean install -B` (baut + testet + packt das Deliverable auf Release-Version)
3. `docker build` / bzw. Jar extrahieren (M3) aus genau diesem Output
4. deploy (blue-green)
5. (nur bei release) `mvn versions:set <next-snapshot>` + commit/push
Dateien: `plaintext-scripts/.github/workflows/ci-cd-pipeline.yaml` (Jobs zusammenführen,
deploy-target-Logik behalten); `tui-build-logic.sh` `do_release` (Build von Versionierung trennen,
`mvn clean deploy` nicht doppelt). Erwartung: ~½ Buildzeit pro Deploy. Risiko: mittel (Pipeline).

### M2 — Maven-Build-Cache korrekt aktivieren (unveränderte Module überspringen)
- `.mvn/extensions.xml` mit `org.apache.maven.extensions:maven-build-cache-extension` (pro App;
  Template in plaintext-scripts), `<enabled>true</enabled>`.
- **WICHTIG (Korrektheits-Falle):** Input-Glob vervollständigen! Aktuell nur
  `{*.java,*.xml,*.properties,*.yaml,*.yml}` → Änderungen an `*.xhtml`, `*.sql` (Flyway!), `*.js`,
  `*.css`, `*.html`, `*.vm`, `*.ftl` würden NICHT invalidieren → **veralteter Deploy**. Glob auf alle
  relevanten Ressourcen erweitern (oder ganzes `src/main/resources`).
- CI-Cache persistieren: `~/.m2/build-cache` via `actions/cache` (ephemerale Runner) ODER fester
  Runner-Pfad. Key stabil halten.
- **Release-Falle:** globaler `versions:set` ändert ALLE Poms → Cache-Key aller Module ändert sich →
  Cache kalt pro Release. Nutzen v. a. für PR/snapshot-Builds (stabile Version). Für Releases ist M1
  der sichere Hebel. (Extension-`projectVersioning` evtl. mildernd — messen.)
Risiko: niedrig-mittel (Korrektheit nur bei richtigem Glob). Gilt sofort für CI/PR-Feedback.

### M3 — Jar im Volume statt Image pro Version (User-Idee; größter Deploy-Hebel)
Eliminiert `docker build` + `docker save|gzip|load` + den Image-Tag-Bump pro Release.
- **Ein gemeinsames Runtime-Image** `ghcr.io/plaintext-gmbh/plaintext-runtime:jre25`
  (FROM eclipse-temurin:25-jre-alpine + bash/wget + appuser(1000) + Entrypoint
  `java $JAVA_OPTS -jar /app/app.jar`). Einmal gebaut, in GHCR. Alle Apps nutzen es; Tag bleibt stabil.
- **Compose** (alle Apps): `image: ghcr.io/...plaintext-runtime:jre25` + Volume-Mount des Jars,
  z. B. `/volume1/docker/<app>/<color>/app.jar:/app/app.jar:ro`. Kein Versions-Tag mehr im Compose
  → kein gitops-Commit/recreate pro Release.
- **Deploy** (`tui-build-logic.sh`): statt `docker build`+`push_to_registry`:
  `scp target/*-exec.jar DEPLOY_SERVER:/volume1/docker/<app>/<inactive-color>/app.jar` →
  `docker restart <app>-<color>` (oder `up -d --no-deps --force-recreate <color>`) → Healthcheck →
  nginx-Switch → alten Slot stoppen. (~50–150 MB Jar statt ganzes Image; kein gzip/load.)
- Versionsanzeige kommt aus dem Jar (`/nosec/version`); blue-green-State trackt aktive Farbe.
- Optional „nur geänderte Module": Jar **exploded** ablegen (`java -Djarmode=tools -jar app.jar
  extract` bzw. layertools) und per `rsync` nur geänderte Dateien syncen. ABER: bei Release bekommen
  alle Modul-Jars neue Versions-Dateinamen → rsync sähe alle als neu. Nutzen nur mit
  versions-stabilen Modul-Jars (unabhängige Modulversionen) — separater, größerer Schritt; für jetzt
  zurückgestellt. Da der Build lokal auf dem NAS läuft, ist der Datei-Transfer ohnehin nicht der
  Engpass; M3 (kein save/load) holt den Großteil.
Risiko: mittel-hoch (Compose+bluegreen+./build aller Apps, PROD). Zuerst plaintext-app DEV erproben.

### M4 — Blue-Green-Healthcheck straffen
- Readiness via `/actuator/health/readiness` statt fixem `start_period: 60s`; `start_period`/retries
  senken, sobald App schneller ready meldet. nginx-Switch sofort bei erstem readiness=UP.
- Spart 1–2 min pro Slot. Risiko: niedrig.

## Empfohlene Reihenfolge (mit Validierung je Schritt auf plaintext-app DEV)
1. **M2** (Cache, Glob korrekt) — sofortiger CI/PR-Gewinn, isoliert.
2. **M1** (einmal bauen) — größter Release-Build-Gewinn.
3. **M3** (Jar im Volume) — größter Deploy-Gewinn, User-Idee; Runtime-Image + Compose + bluegreen.
4. **M4** (Healthcheck) — Feinschliff.
5. Rollout M1–M4 auf root/iot/schuetu/fwtool (Compose je App in plaintext-dockercompose).

Jeder Schritt: Branch → plaintext-app DEV deployen/messen → bei grün PROD + Rollout.
Keine parallelen Builds während eines PROD-Deploys (ephemerale NAS-Runner → blue-green-Abbruch).
