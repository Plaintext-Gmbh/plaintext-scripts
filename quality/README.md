# Qualitätswerkzeuge (`quality/`)

Zentrale, projektübergreifende Code-Qualitäts-Skripte für die Plaintext-Spring-Familie
(root, app, iot, fwtool, schuetu). Ergänzen die bereits in der CI laufenden Werkzeuge
(JUnit + JaCoCo, SonarQube, ArchUnit).

## Übersicht

| Skript | Zweck | Braucht Maven |
|---|---|---|
| `quality-dashboard.py` | HTML-Übersicht aller Projekte (Sonar-Kennzahlen, Gate, CI, PRs) + Handlungsbedarf | nein (REST) |
| `quality-gate.py` | wertet Sonar-Gate + OWASP-CVE aus, schreibt `quality/quality-gate.properties`, Exit 10 bei Breach | nein (REST) |
| `owasp-dependency-check.sh` | CVE-Scan der Maven-Abhängigkeiten (NVD) | ja |
| `spotbugs.sh` | Statische Bytecode-Analyse + FindSecBugs (Security) | ja |
| `pushover.sh` | CI-Benachrichtigung (env: `PUSHOVER_APP_TOKEN`/`PUSHOVER_USER_KEY`) | nein |

> Die Linux-Box hat **kein lokales Maven** — die mvn-basierten Skripte laufen in der CI
> oder auf einer Dev-Maschine. Die Python-Skripte ziehen ihre Daten über REST und laufen überall.

## Pipeline-Rhythmus (pro Projekt)

- **Nightly** (`0 3 * * *`): schneller `ci-only`-Build — Unit-Tests + ArchUnit, **kein** Sonar. Fängt Regressionen schnell.
- **Weekly** (`0 4 * * 1`): Voll-Analyse — SonarQube (NAS) + OWASP-CVE + SpotBugs, dann Quality-Gate-Bewertung.
- **Weekly Dashboard** (`0 6 * * 1`, `quality-dashboard.yaml`): Gesamt-HTML über alle 5 Projekte → **GitHub Pages** (`https://plaintext-gmbh.github.io/plaintext-scripts/`).

### Ein manueller Dispatch löst die Voll-Analyse aus — auch ausserhalb des Montags

```bash
gh workflow run "Build And Deploy" -R Plaintext-Gmbh/plaintext-<repo> -f deploy-target=ci-only
```

Die Consumer-Workflows schalten Sonar und die Quality-Analyse an **zwei** Bedingungen:

```yaml
sonar-enabled:    ${{ github.event.schedule == '0 4 * * 1' || github.event_name == 'workflow_dispatch' }}
quality-analysis: ${{ github.event.schedule == '0 4 * * 1' || github.event_name == 'workflow_dispatch' }}
```

Ein `workflow_dispatch` erzeugt damit einen **vollständigen** Analyse-Lauf. Das ist mehr als eine
Bequemlichkeit: Das Quality-Gate wird nur in diesem Lauf neu bewertet. Ein Fund, der am Dienstag
behoben wird, hält `quality/quality-gate.properties` sonst bis zum folgenden Montag auf `BREACHED`
und färbt **jeden** Build rot — für etwas, das es nicht mehr gibt. Am 03.08.2026 ging
`plaintext-fwtool` mit einem einzigen Dispatch von `BREACHED` auf `OK` (Karte 420).

Wer dreimal erlebt, dass Rot „schon behoben" heisst, schaut beim vierten Mal nicht mehr hin —
genau so wurde das Gate am 21.07.2026 stummgeschaltet (Karte 365). **Ein veraltetes Rot gehört
neu bewertet, nicht ausgehalten.** Preis: ein voller Lauf (auf dem kleinsten Repo rund 70 Minuten,
davon der Löwenanteil OWASP), also nicht beiläufig, aber jederzeit möglich.

## Suppressions: was die Datei `quality/owasp-suppressions.xml` verspricht — und wer es einhält

Ein CVE-Fund ohne verfügbaren Fix wird **version-gepinnt** ausgenommen
(`pkg:maven/<group>/<artifact>@<version>`). Der Pin **ist** das Ablaufdatum: Zieht das Framework
eine neue Version, greift die Suppression nicht mehr und der neue Stand wird erneut bewertet. Ein
**False Positive** darf offen bleiben (`@.*`), muss die Fehlzuordnung aber in `<notes>` benennen —
Musterfall `mxparser`, das OWASP wegen der groupId der XStream-CPE zuordnet.

Die Lücke dieses Mechanismus war nicht der Ablauf, sondern **dass niemand den abgelaufenen Eintrag
bemerkt**: Er bleibt stehen und liest sich weiter wie eine begründete Ausnahme. So trugen am
06.08.2026 vier Repos eine Suppression auf `tomcat-embed-*@11.0.22`, während ihr Build längst
11.0.24 auflöste — in zwei davon zusätzlich nur für `tomcat-embed-core`, ohne das
Schwester-Artefakt `-websocket` mit denselben acht CVEs.

**Durchgesetzt wird das jetzt im normalen Build, nicht durch eine Frist:**
`PlaintextOwaspSuppressionsTest` in `plaintext-root-archtests` läuft über Surefire
`<dependenciesToScan>` in jedem Consumer mit und meldet jeden Eintrag, dessen Version im
**aufgelösten Klassenpfad** nicht mehr vorkommt (auch `regex="true"`-Einträge, solange ihr
Versionsteil fest ist). Repositories ohne Suppression-Datei überspringt er sichtbar — die Pipeline
übergibt die Datei ebenfalls nur, wenn es sie gibt.

> **Noch nicht festgelegt** (Karte 420, Frage 2): **wer** einen neuen Fund ohne Fix fachlich
> bewertet und in welcher Frist. Der Test sagt nur, ob eine Ausnahme noch *greift* — nicht, ob sie
> noch *berechtigt* ist. Solange das offen ist, hängt die Bewertung an dem, der den Weekly-Alert
> liest.

## Quality-Gate-Ratchet

Auslöser (Schwelle überschritten): **SonarQube-Quality-Gate = ERROR** ODER **neue CVE mit CVSS ≥ 7** (OWASP).
Bei Breach schreibt `quality-gate.py` das File `quality/quality-gate.properties` (status=BREACHED + Breach-Zeilen +
Links) ins Projekt-Repo, die Weekly-Pipeline **committet** es (`[skip-ci]`) und schickt **Pushover** (high prio).
Der `QualityGateTest` (`@Tag("quality-gate")`) jedes Projekts liest das File und **schlägt mit dem Inhalt als
Meldung fehl** — in nightly/PR/lokal. Der **Deploy-Pfad überspringt** den Tag (`-DexcludedGroups=quality-gate`),
damit ein Hotfix trotz aktivem Alert rausgeht. Nach Fix setzt der nächste Weekly-Lauf wieder `status=OK`.

## quality-dashboard.py

```bash
quality/quality-dashboard.py [ausgabe.html]      # Default: ./quality-dashboard.html
```

Zieht live: letzter master-CI-Lauf (nur echte `push`-Deploys, Nightlies ignoriert),
offene PRs, CodeQL-Alerts, SonarQube-Projektzahl (via NAS), Test-/Prod-Klassen und
ArchUnit-Präsenz. Rendert eine standalone HTML-Seite mit Statustabelle und einem
kuratierten, nach Schweregrad sortierten Handlungsbedarf.

## owasp-dependency-check.sh

```bash
export NVD_API_KEY=<key>                          # dringend empfohlen (sonst langsam/rate-limited)
quality/owasp-dependency-check.sh <projekt-dir> [fail-cvss]
```

Scannt alle Dependencies gegen die NVD-CVE-Datenbank; Reports unter
`<projekt>/target/dependency-check-report.{html,json}`. `fail-cvss` (z. B. `7`) lässt den
Build ab dieser CVSS-Schwelle scheitern (Default `0` = nie failen, nur berichten).

**CI-Einbau (Vorschlag):** wöchentlicher Job analog zum SonarQube-Cron; `NVD_API_KEY` als
GitHub-Secret. Report als Artefakt hochladen.

## spotbugs.sh

```bash
quality/spotbugs.sh <projekt-dir> [Low|Medium|High]   # Default: Medium
```

SpotBugs (Effort Max) + FindSecBugs-Plugin über den kompilierten Bytecode. Sinnvoll vor
allem dort, wo **CodeQL nicht aktiv** ist (aktuell alle außer root). Reports je Modul unter
`target/spotbugsXml.xml`.

## Versionen

Plugin-Versionen sind oben in den Skripten als Variablen gepflegt
(`OWASP_DC_VERSION`, `SPOTBUGS_VERSION`, `FINDSECBUGS_VERSION`) und per Env überschreibbar.
