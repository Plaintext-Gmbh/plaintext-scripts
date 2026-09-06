#!/usr/bin/env python3
"""
quality-dashboard.py — standalone HTML-Übersicht der Code-Qualität über alle
Plaintext-Spring-Projekte + priorisierter Handlungsbedarf.

Datenquellen (env-getrieben, CI-tauglich; kein Maven, kein `gh`, kein ssh nötig):
  - GitHub REST (Token aus GH_TOKEN, sonst `gh auth token`): letzter master-Deploy,
    offene PRs, CodeQL-Alerts.
  - SonarQube REST (SONAR_URL + SONAR_TOKEN): Quality-Gate + Kennzahlen
    (ncloc, coverage, bugs, vulnerabilities, code_smells) je Projekt.
  - Quality-Gate-Statusfile je Repo (quality/quality-gate.properties) via GitHub-Contents.

Nutzung:  quality/quality-dashboard.py [ausgabe.html]     (Default: ./quality-dashboard.html)
Env:      GH_TOKEN, SONAR_URL (Default https://sonarqube.plaintext.ch), SONAR_TOKEN
"""
import base64
import datetime
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

ORG = "Plaintext-Gmbh"
GROUP = "ch.plaintext"
SONAR_URL = os.environ.get("SONAR_URL", "https://sonarqube.plaintext.ch").rstrip("/")
SONAR_TOKEN = os.environ.get("SONAR_TOKEN", "")

# (Repo, Sonar-artifactId) — die fünf Spring-Anwendungen (Parent-Artifact als Sonar-Projektschlüssel).
PROJECTS = [
    ("plaintext-root", "plaintext-root-parent"),
    ("plaintext-app", "plaintext-parent"),
    ("plaintext-iot", "plaintext-iot-parent"),
    ("plaintext-fwtool", "plaintext-fwtool-parent"),
    ("plaintext-schuetu", "plaintext-schuetu-parent"),
]


def gh_token():
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t
    try:
        return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except Exception:
        return ""


TOKEN = gh_token()


def _get(url, headers, timeout=20):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read().decode())


def gh(path):
    """GitHub REST GET; (status, data) oder (code, None) bei Fehler."""
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "quality-dashboard"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    try:
        return _get(f"https://api.github.com/{path}", headers)
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None


def sonar(path):
    """SonarQube REST GET; data oder None."""
    headers = {"User-Agent": "quality-dashboard"}
    if SONAR_TOKEN:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{SONAR_TOKEN}:".encode()).decode()
    try:
        _, data = _get(f"{SONAR_URL}/api/{path}", headers)
        return data
    except Exception:
        return None


def latest_master_run(repo):
    _, data = gh(f"repos/{ORG}/{repo}/actions/runs?branch=master&per_page=40")
    runs = (data or {}).get("workflow_runs", []) if data else []
    for r in runs:
        if r.get("event") == "push" and r.get("status") != "completed":
            return "läuft", (r.get("created_at") or "")[:10]
    for r in runs:
        if r.get("event") == "push" and r.get("conclusion") in ("success", "failure"):
            return r["conclusion"], (r.get("created_at") or "")[:10]
    for r in runs:
        if r.get("conclusion") in ("success", "failure"):
            return r["conclusion"] + " (nightly)", (r.get("created_at") or "")[:10]
    return "?", ""


def open_prs(repo):
    _, data = gh(f"repos/{ORG}/{repo}/pulls?state=open&per_page=100")
    return len(data) if isinstance(data, list) else 0


def codeql(repo):
    st, data = gh(f"repos/{ORG}/{repo}/code-scanning/alerts?state=open&per_page=100")
    if isinstance(data, list):
        return "aktiv", len(data)
    return "inaktiv", 0


def gate_file_status(repo):
    """quality/quality-gate.properties via Contents-API → 'OK'|'BREACHED'|None."""
    _, data = gh(f"repos/{ORG}/{repo}/contents/quality/quality-gate.properties")
    if not data or "content" not in data:
        return None
    try:
        text = base64.b64decode(data["content"]).decode("utf-8")
        for line in text.splitlines():
            if line.startswith("status="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return None


def sonar_measures(artifact):
    key = f"{GROUP}:{artifact}"
    keys = "alert_status,coverage,ncloc,bugs,vulnerabilities,code_smells,security_hotspots"
    data = sonar(f"measures/component?component={key}&metricKeys={keys}")
    if not data or "component" not in data:
        return None
    out = {}
    for m in data["component"].get("measures", []):
        out[m["metric"]] = m.get("value")
    return out


def badge(color, text):
    return (f'<span style="background:{color};color:#fff;padding:2px 8px;'
            f'border-radius:10px;font-size:12px">{text}</span>')


CI_COLOR = {"success": "#3f9e57", "läuft": "#888", "failure": "#d64545"}


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "quality-dashboard.html"
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    dash_url = "https://plaintext-gmbh.github.io/plaintext-scripts/"

    rows, breaches, sonar_seen = [], [], 0
    for repo, artifact in PROJECTS:
        concl, when = latest_master_run(repo)
        prs = open_prs(repo)
        cq_status, cq_n = codeql(repo)
        gate = gate_file_status(repo)
        m = sonar_measures(artifact) or {}
        if m:
            sonar_seen += 1
        cov = m.get("coverage")
        ncloc = m.get("ncloc")
        bugs = m.get("bugs")
        vulns = m.get("vulnerabilities")
        smells = m.get("code_smells")
        sonar_gate = m.get("alert_status")  # OK | ERROR | WARN

        ci_c = CI_COLOR.get(concl.split(" ")[0], "#888")
        gate_disp = badge("#d64545", "BREACHED") if gate == "BREACHED" else (
            badge("#3f9e57", "OK") if gate == "OK" else '<span style="color:#aaa">–</span>')
        if gate == "BREACHED":
            breaches.append(repo)
        sonar_cell = (f'{cov or "?"}% cov · {bugs or "0"} bugs · {vulns or "0"} vulns'
                      if m else '<span style="color:#aaa">keine Analyse</span>')
        gate_hint = ""
        if sonar_gate == "ERROR":
            gate_hint = ' <span style="color:#d64545">●</span>'
        cq_cell = (f"{cq_n} Alert(s)" if cq_status == "aktiv" else badge("#d64545", "inaktiv"))

        rows.append(f"""
        <tr>
          <td><b>{repo}</b><br><span style="color:#999;font-size:11px">{ncloc or '?'} LOC</span></td>
          <td>{badge(ci_c, concl)}<br><span style="color:#999;font-size:11px">{when}</span></td>
          <td style="font-size:13px">{sonar_cell}{gate_hint}</td>
          <td style="text-align:center">{gate_disp}</td>
          <td style="text-align:center;font-size:12px">{cq_cell}</td>
          <td style="text-align:center">{prs}</td>
        </tr>""")

    # Handlungsbedarf: live (Gate-Breaches) + kuratierte Infra-Punkte.
    hb = []
    if breaches:
        hb.append(("crit", f"Quality-Gate rot: {', '.join(breaches)}",
                   "Wöchentliche Voll-Analyse hat die Schwelle überschritten (Sonar-Gate ERROR "
                   "oder High-CVE). Statusfile ist eingecheckt, nightly/PR-Builds sind rot bis zum Fix. "
                   "Details siehe Sonar-Dashboard des Projekts."))
    if sonar_seen == 0:
        hb.append(("high", "SonarQube hat noch keine Analyse-Daten",
                   "Sobald der erste wöchentliche Voll-Lauf durch ist, erscheinen hier Coverage, Bugs "
                   "und Vulnerabilities je Projekt. (SONAR_TOKEN neu gesetzt 2026-07-03.)"))
    hb += [
        ("med", "CVE-Scan (OWASP) läuft best-effort ohne NVD-Key",
         "Für schnelle, verlässliche CVE-Ergebnisse ein NVD_API_KEY als GitHub-Secret setzen "
         "(kostenlos: nvd.nist.gov). Ohne Key ist der Erst-Sync langsam; der Gate fällt dann auf "
         "Sonar-only zurück."),
        ("med", "CodeQL nur in plaintext-root aktiv",
         "4 von 5 Repos ohne GitHub Advanced Security. SpotBugs+FindSecBugs läuft wöchentlich als "
         "Ersatz (quality/spotbugs.sh); für native Alerts Advanced Security je Repo aktivieren."),
        ("low", "ArchUnit-Regeln in allen 5 Projekten aktiv",
         "@Scheduled-Verbot + PlaintextCron-prototype + Quality-Gate-Wächter. Nächste Stufe: "
         "Jackson-3-/Mail-Kapselungs-Regeln aus app auch nach root/iot/schuetu tragen."),
    ]
    SEV = {"crit": ("#d64545", "KRITISCH"), "high": ("#e8830c", "HOCH"),
           "med": ("#e0b400", "MITTEL"), "low": ("#3f9e57", "NIEDRIG")}
    hb_html = []
    for sev, title, detail in sorted(hb, key=lambda x: list(SEV).index(x[0])):
        color, label = SEV[sev]
        hb_html.append(f"""
        <div style="border-left:4px solid {color};background:#fafafa;margin:10px 0;padding:10px 14px;border-radius:4px">
          <span style="background:{color};color:#fff;padding:1px 8px;border-radius:8px;font-size:11px;font-weight:bold">{label}</span>
          <b style="margin-left:8px">{title}</b>
          <div style="color:#444;margin-top:5px;font-size:14px">{detail}</div>
        </div>""")

    html = f"""<!DOCTYPE html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plaintext · Code-Qualität</title>
<style>
  body {{ font-family:-apple-system,Segoe UI,Roboto,sans-serif; margin:0; background:#f0f2f5; color:#222; }}
  .wrap {{ max-width:1000px; margin:0 auto; padding:24px; }}
  h1 {{ margin-bottom:4px; }} .sub {{ color:#888; margin-bottom:24px; }}
  .card {{ background:#fff; border-radius:8px; padding:18px 22px; margin-bottom:20px; box-shadow:0 1px 3px rgba(0,0,0,.08); }}
  table {{ width:100%; border-collapse:collapse; }}
  th,td {{ padding:10px 8px; border-bottom:1px solid #eee; text-align:left; font-size:14px; }}
  th {{ color:#666; font-size:12px; text-transform:uppercase; letter-spacing:.4px; }}
  .tools li {{ margin:4px 0; }}
</style></head>
<body><div class="wrap">
  <h1>🛡️ Code-Qualität · Plaintext-Projektfamilie</h1>
  <div class="sub">Erzeugt {now} · wöchentliche Voll-Analyse (Sonar auf NAS) · quality/quality-dashboard.py</div>

  <div class="card">
    <h2 style="margin-top:0">Übersicht je Projekt</h2>
    <table>
      <tr><th>Projekt</th><th>letzter master-Deploy</th><th>SonarQube</th><th>Quality-Gate</th><th>CodeQL</th><th>PRs</th></tr>
      {''.join(rows)}
    </table>
    <div style="color:#999;font-size:12px;margin-top:8px">Quality-Gate = eingechecktes Statusfile
      (BREACHED ⇒ nightly/PR-Builds rot + Pushover). <span style="color:#d64545">●</span> = Sonar-Gate ERROR.</div>
  </div>

  <div class="card">
    <h2 style="margin-top:0">🚩 Handlungsbedarf (priorisiert)</h2>
    {''.join(hb_html)}
  </div>

  <div class="sub" style="text-align:center">Plaintext GmbH · automatisch generiert · <a href="{dash_url}">{dash_url}</a></div>
</div></body></html>"""

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"Dashboard geschrieben: {out_path} (Sonar-Projekte mit Daten: {sonar_seen}/5, Breaches: {len(breaches)})")


if __name__ == "__main__":
    main()
