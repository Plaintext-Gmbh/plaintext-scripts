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
