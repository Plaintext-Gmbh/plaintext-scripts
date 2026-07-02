#!/usr/bin/env python3
"""
quality-dashboard.py — erzeugt eine standalone HTML-Übersicht der Code-Qualität
über alle Plaintext-Spring-Projekte und zeigt den priorisierten Handlungsbedarf.

Zieht Live-Daten (kein Maven nötig):
  - GitHub: letzter master-CI-Lauf, offene PRs, CodeQL-Alerts   (via `gh`)
  - SonarQube: Anzahl analysierter Projekte                     (via `ssh` NAS + docker exec)
  - Test-/Prod-Klassen, ArchUnit-Präsenz                        (lokale Checkouts)

Nutzung:  quality/quality-dashboard.py [ausgabe.html]
Default-Ausgabe: ./quality-dashboard.html
"""
import json
import subprocess
import sys
import datetime

ORG = "Plaintext-Gmbh"
CODE_ROOT = "/home/mad/codeplain"
NAS_SSH = "mad@192.100.0.1"

# (Repo, lokaler Pfad) — die fünf Spring-Anwendungen.
PROJECTS = [
    ("plaintext-root", "plaintext-root"),
    ("plaintext-app", "plaintext-app"),
    ("plaintext-iot", "plaintext-iot"),
    ("plaintext-fwtool", "plaintext-fwtool"),
    ("plaintext-schuetu", "plaintext-schuetu"),
]


def sh(cmd, timeout=30):
    """Führt ein Kommando aus, gibt stdout (str) zurück, '' bei Fehler/Timeout."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def gh_json(path):
    out = sh(["gh", "api", path])
    if not out:
        return None
    try:
        return json.loads(out)
    except Exception:
        return None


def latest_master_run(repo):
    """Letzter echter Deploy-/Build-Lauf auf master (push-Event, nicht skip-ci).
    Nächtliche `schedule`-Läufe (nur SonarQube-Infra, oft rot) werden bewusst
    ignoriert, damit die Tabelle die tatsächliche Deploy-Gesundheit zeigt."""
    out = sh(["gh", "run", "list", "--repo", f"{ORG}/{repo}", "--branch", "master",
             "--limit", "40", "--json", "conclusion,createdAt,event,status"])
    try:
        arr = json.loads(out)
    except Exception:
        return "?", ""
    # 1) laufender push-Lauf?
    for r in arr:
        if r.get("event") == "push" and r.get("status") != "completed":
            return "läuft", (r.get("createdAt") or "")[:10]
    # 2) letzter abgeschlossener push-Lauf mit echtem Ergebnis (echte Deploy-Gesundheit)
    for r in arr:
        if r.get("event") == "push" and r.get("conclusion") in ("success", "failure"):
            return r["conclusion"], (r.get("createdAt") or "")[:10]
    # 3) Fallback: kein push-Lauf im Fenster (nur Nightlies) → letztes echtes Ergebnis, markiert
    for r in arr:
        if r.get("conclusion") in ("success", "failure"):
            return r["conclusion"] + " (nightly)", (r.get("createdAt") or "")[:10]
    return "?", ""


def open_prs(repo):
    out = sh(["gh", "pr", "list", "--repo", f"{ORG}/{repo}", "--state", "open", "--json", "number"])
    try:
        return len(json.loads(out))
    except Exception:
        return 0


def codeql_alerts(repo):
    """(status, count): 'aktiv'/n, oder 'inaktiv' wenn Advanced Security aus."""
    out = sh(["gh", "api", f"repos/{ORG}/{repo}/code-scanning/alerts?state=open&per_page=100"])
    try:
        data = json.loads(out)
        if isinstance(data, list):
            return "aktiv", len(data)
        return "inaktiv", 0
    except Exception:
        return "inaktiv", 0


def local_counts(path):
    base = f"{CODE_ROOT}/{path}"
    tests = sh(["bash", "-c",
                f"find {base} -path '*/src/test/*Test.java' 2>/dev/null | grep -v /target/ | wc -l"])
    prod = sh(["bash", "-c",
               f"find {base} -path '*/src/main/*.java' 2>/dev/null | grep -v /target/ | wc -l"])
    arch = sh(["bash", "-c",
               f"find {base} -name ArchitectureTest.java 2>/dev/null | grep -v /target/ | wc -l"])
    try:
        return int(tests or 0), int(prod or 0), int(arch or 0) > 0
    except Exception:
        return 0, 0, False


def sonar_project_count():
    # SonarQube ist nur im internen Docker-Netz erreichbar → Abfrage im Container.
    cmd = ("sudo docker exec sonarqube sh -c "
           "\"wget -q -O- 'http://localhost:9000/api/projects/search?ps=100' 2>/dev/null\" 2>/dev/null "
           "| head -c 100000")
    out = sh(["ssh", "-o", "ConnectTimeout=10", NAS_SSH, cmd], timeout=25)
    try:
        return len(json.loads(out).get("components", []))
    except Exception:
        return None


# Kuratierter Handlungsbedarf (aus der Session-Analyse + Security-Audit-Historie).
# severity: crit | high | med | low ; jeweils (Titel, Detail).
HANDLUNGSBEDARF = [
    ("high", "SonarQube analysiert 0 Projekte",
     "Container läuft (7d up, vm.max_map_count gefixt), aber es sind keine Projekte analysiert. "
     "Der wöchentliche Sonar-Cron pusht faktisch nichts → Quality Gates ungenutzt. "
     "Sonar-Job-Fehler in der Pipeline prüfen, SONAR_TOKEN/Projektanlage verifizieren."),
    ("high", "CVE-Scan der Abhängigkeiten fehlt überall",
     "Kein Projekt scannt seine Maven-Dependencies gegen bekannte CVEs. "
     "Neu: quality/owasp-dependency-check.sh — als wöchentlichen CI-Job einhängen (NVD_API_KEY setzen)."),
    ("med", "CodeQL nur in plaintext-root aktiv",
     "4 von 5 Repos: Advanced Security nicht aktiviert, daher keine Code-Scanning-Alerts. "
     "GitHub Advanced Security / CodeQL-Default-Setup je Repo aktivieren (oder SpotBugs+FindSecBugs "
     "via quality/spotbugs.sh als Ersatz einhängen)."),
    ("med", "root: 1 High-CodeQL-Alert offen (DOM-XSS)",
     "js/xss-through-dom in index.xhtml (high) + java/error-message-exposure in "
     "UserPreferencesRestController.java (medium). Beheben oder als Alert triagieren."),
    ("med", "Test-Abdeckung niedrig in fwtool & app",
     "Testklassen/Prod-Klassen: fwtool 12/54 (22%), app 158/530 (30%). Kritische Pfade "
     "(Rechnungen, Postkonto-Parsing, Auszahlungen) priorisiert absichern."),
    ("low", "ArchUnit-Regeln nur teilweise ausgerollt",
     "Nach diesem Sweep in allen 5 Projekten aktiv (@Scheduled-Verbot + PlaintextCron-prototype). "
     "Nächste Stufe: weitere Regeln (Jackson-3, Mail-Kapselung, Modul-Grenzen) auch nach "
     "root/iot/schuetu tragen — siehe app ArchitectureTest."),
    ("low", "Security-Audit (ZAP) aktualisieren",
     "Letzter vollständiger ZAP-Lauf stammt aus einer früheren Session (3 kritische, 4 hohe, "
     "9 mittlere Befunde). Erneut laufen lassen und Status gegen die inzwischen gefixten Punkte abgleichen."),
]

SEV = {
    "crit": ("#d64545", "KRITISCH"), "high": ("#e8830c", "HOCH"),
    "med": ("#e0b400", "MITTEL"), "low": ("#3f9e57", "NIEDRIG"),
}


def badge(ok, text):
    color = "#3f9e57" if ok else "#d64545"
    return f'<span style="background:{color};color:#fff;padding:2px 8px;border-radius:10px;font-size:12px">{text}</span>'


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "quality-dashboard.html"
    now = sh(["date", "+%Y-%m-%d %H:%M"])
    sonar_n = sonar_project_count()

    rows = []
    for repo, path in PROJECTS:
        concl, when = latest_master_run(repo)
        prs = open_prs(repo)
        cq_status, cq_n = codeql_alerts(repo)
        tests, prod, has_arch = local_counts(path)
        ratio = f"{round(100*tests/prod)}%" if prod else "–"
        ci_ok = concl == "success"
        cq_cell = f"{cq_n} Alert(s)" if cq_status == "aktiv" else "—"
        rows.append(f"""
        <tr>
          <td><b>{repo}</b></td>
          <td>{badge(ci_ok, concl)}<br><span style="color:#888;font-size:11px">{when}</span></td>
          <td style="text-align:center">{tests} / {prod}<br><span style="color:#888;font-size:11px">{ratio}</span></td>
          <td style="text-align:center">{badge(has_arch, 'ja' if has_arch else 'nein')}</td>
          <td style="text-align:center">{'aktiv' if cq_status=='aktiv' else badge(False,'inaktiv')}<br><span style="font-size:11px">{cq_cell}</span></td>
          <td style="text-align:center">{prs}</td>
        </tr>""")

    hb = []
    for sev, title, detail in sorted(HANDLUNGSBEDARF, key=lambda x: list(SEV).index(x[0])):
        color, label = SEV[sev]
        hb.append(f"""
        <div style="border-left:4px solid {color};background:#fafafa;margin:10px 0;padding:10px 14px;border-radius:4px">
          <span style="background:{color};color:#fff;padding:1px 8px;border-radius:8px;font-size:11px;font-weight:bold">{label}</span>
          <b style="margin-left:8px">{title}</b>
          <div style="color:#444;margin-top:5px;font-size:14px">{detail}</div>
        </div>""")

    sonar_line = (f"{sonar_n} analysierte Projekte" if sonar_n is not None else "nicht abfragbar")
    sonar_ok = bool(sonar_n)

    html = f"""<!DOCTYPE html>
<html lang="de"><head><meta charset="utf-8">
<title>Plaintext · Code-Qualität</title>
<style>
  body {{ font-family: -apple-system, Segoe UI, Roboto, sans-serif; margin: 0; background:#f0f2f5; color:#222; }}
  .wrap {{ max-width: 1000px; margin: 0 auto; padding: 24px; }}
  h1 {{ margin-bottom:4px; }} .sub {{ color:#888; margin-bottom:24px; }}
  .card {{ background:#fff; border-radius:8px; padding:18px 22px; margin-bottom:20px; box-shadow:0 1px 3px rgba(0,0,0,.08); }}
  table {{ width:100%; border-collapse:collapse; }}
  th,td {{ padding:10px 8px; border-bottom:1px solid #eee; text-align:left; font-size:14px; }}
  th {{ color:#666; font-size:12px; text-transform:uppercase; letter-spacing:.4px; }}
  .tools li {{ margin:4px 0; }}
</style></head>
<body><div class="wrap">
  <h1>🛡️ Code-Qualität · Plaintext-Projektfamilie</h1>
  <div class="sub">Erzeugt {now} · quality/quality-dashboard.py</div>

  <div class="card">
    <h2 style="margin-top:0">Übersicht je Projekt</h2>
    <table>
      <tr><th>Projekt</th><th>letzter master-CI</th><th>Tests / Prod</th><th>ArchUnit</th><th>CodeQL</th><th>offene PRs</th></tr>
      {''.join(rows)}
    </table>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Qualitätswerkzeuge — Status</h2>
    <ul class="tools">
      <li>✅ <b>JUnit + JaCoCo</b> — läuft in jedem CI (Coverage-Report als Artefakt)</li>
      <li>{'✅' if has_arch else '⚠️'} <b>ArchUnit</b> — Architektur-Regeln (@Scheduled-Verbot, PlaintextCron-prototype) in allen 5 Projekten</li>
      <li>{'✅' if sonar_ok else '⚠️'} <b>SonarQube</b> — Container läuft; {sonar_line}</li>
      <li>⚠️ <b>CodeQL / GitHub Advanced Security</b> — nur plaintext-root aktiv</li>
      <li>❌ <b>OWASP Dependency-Check</b> (CVE-Scan) — Skript vorhanden (quality/owasp-dependency-check.sh), noch nicht eingehängt</li>
      <li>❌ <b>SpotBugs + FindSecBugs</b> — Skript vorhanden (quality/spotbugs.sh), noch nicht eingehängt</li>
      <li>ℹ️ <b>Renovate</b> — Dependency-Update-PRs aktiv (siehe Spalte offene PRs)</li>
    </ul>
  </div>

  <div class="card">
    <h2 style="margin-top:0">🚩 Handlungsbedarf (priorisiert)</h2>
    {''.join(hb)}
  </div>

  <div class="sub" style="text-align:center">Plaintext GmbH · automatisch generiert</div>
</div></body></html>"""

    with open(out_path, "w") as f:
        f.write(html)
    print(f"Dashboard geschrieben: {out_path}")


if __name__ == "__main__":
    main()
