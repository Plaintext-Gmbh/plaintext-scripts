# Qualitätswerkzeuge (`quality/`)

Zentrale, projektübergreifende Code-Qualitäts-Skripte für die Plaintext-Spring-Familie
(root, app, iot, fwtool, schuetu). Ergänzen die bereits in der CI laufenden Werkzeuge
(JUnit + JaCoCo, SonarQube, ArchUnit).

## Übersicht

| Skript | Zweck | Braucht Maven | Läuft auf der Linux-Box |
|---|---|---|---|
| `quality-dashboard.py` | HTML-Übersicht aller Projekte + priorisierter Handlungsbedarf | nein (nur `gh`/`ssh`) | ✅ ja |
| `owasp-dependency-check.sh` | CVE-Scan der Maven-Abhängigkeiten (NVD) | ja | ❌ nur CI/Dev |
| `spotbugs.sh` | Statische Bytecode-Analyse + FindSecBugs (Security) | ja | ❌ nur CI/Dev |

> Die Linux-Box hat **kein lokales Maven** — die mvn-basierten Skripte laufen in der CI
> oder auf einer Dev-Maschine. Das Dashboard zieht seine Daten über APIs und läuft überall.

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
