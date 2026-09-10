#!/usr/bin/env python3
"""
quality-gate.py — wertet die wöchentliche Voll-Analyse aus und schreibt das
Quality-Gate-Statusfile in das Projekt-Repo.

Auslöser eines Breach (konfiguriert über die Session-Entscheidung):
  1) SonarQube Quality Gate = ERROR
  2) OWASP Dependency-Check: mind. 1 CVE mit CVSS >= Schwelle (Default 7.0)

Schreibt `<repo>/quality/quality-gate.properties` (UTF-8):
  status=OK|BREACHED  + sonar.status, cve.high.count, breach.N=..., *.url, checked
Der zugehörige JUnit-/ArchUnit-Test im Projekt liest dieses File und schlägt bei
status=BREACHED mit sprechender Meldung (den breach.N-Zeilen) fehl.

Exit-Code: 0 = OK · 10 = BREACHED · 2 = Aufruffehler
(Der Exit-Code steuert den Pushover-/Commit-Schritt im Workflow.)
"""
import argparse
import base64
import datetime
import json
import os
import sys
import time
import urllib.request
import urllib.error


def http_get(url, token=None, timeout=15):
    req = urllib.request.Request(url)
    if token:
        # Sonar-Token: Basic <token>: (User = Token, leeres Passwort)
        raw = base64.b64encode(f"{token}:".encode()).decode()
        req.add_header("Authorization", f"Basic {raw}")
    # KARTE 1177: Der User-Agent ist NICHT Kosmetik. sonarqube.plaintext.ch liegt hinter
    # Cloudflare, und Cloudflare beantwortet den Standard-UA von Pythons urllib
    # ("Python-urllib/3.x") mit HTTP 403 und "error code: 1010" — mit gueltigem Token, an
    # einer erreichbaren URL. Gegenprobe am 10.09.2026, selbes Token, selbe URL:
    #     Default-UA "Python-urllib/3.x"  -> 403, error code: 1010
    #     UA "curl/8.0"                   -> 200, projectStatus.status = ERROR
    # Genau daran hing `sonar.status=UNKNOWN` in FUENF von sechs Repos: der 403 fiel unten in
    # ein `except Exception: pass`, wurde zehnmal wiederholt und endete als "nicht erreichbar".
    # Die Sonar-Bewertung ist deshalb seit Wochen ueberhaupt nicht in die Bauentscheidung
    # eingeflossen — ohne dass irgendwo ein Fehler sichtbar wurde.
    # Dieselbe Kante hat ~/scripts/sonar-wochenkarte schon einmal getroffen (dort steht der
    # Header seit Karte 484 drin, Zeile 161-165); die Erkenntnis wurde nie hierher uebertragen.
    # Wer den Header entfernt, schaltet die Sonar-Seite des Gates lautlos wieder ab.
    req.add_header("User-Agent", "curl/8.0")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def wait_for_ce_task(report_task_path, token, tries=20, delay=6):
    """Wartet auf Abschluss der SonarQube-Compute-Engine-Analyse (report-task.txt)."""
    if not report_task_path or not os.path.exists(report_task_path):
        return
    props = {}
    for line in open(report_task_path, encoding="utf-8"):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            props[k] = v
    ce_url = props.get("ceTaskUrl")
    if not ce_url:
        return
    for _ in range(tries):
        try:
            status = http_get(ce_url, token).get("task", {}).get("status")
            if status in ("SUCCESS", "FAILED", "CANCELED"):
                return
        except Exception:
            pass
        time.sleep(delay)


def sonar_gate_status(sonar_url, project_key, token, tries=10, delay=6):
    """(status, grund, bedingungen)

    status: OK | ERROR | WARN | NONE | UNKNOWN (letzteres = nicht erreichbar).
    grund:  "" bei Erfolg, sonst die letzte Fehlerursache im Klartext.
    bedingungen: Liste der Gate-Bedingungen aus der Antwort (leer, wenn keine Antwort kam).

    KARTE 1177: Vorher wurde JEDE Ausnahme in `pass` verschluckt und nach zehn Versuchen als
    "UNKNOWN" gemeldet. Ein 403 der Cloudflare-Kante, ein abgelaufenes Token und ein wirklich
    ausgefallener Server sahen damit gleich aus — und "UNKNOWN" loest keinen Breach aus, das
    Gate stand also gruen. Ein Gate, das nicht messen kann und das nicht sagt, ist schlimmer
    als kein Gate. Deshalb wird die Ursache ab jetzt mitgegeben und in die Properties-Datei
    geschrieben.
    """
    url = f"{sonar_url.rstrip('/')}/api/qualitygates/project_status?projectKey={project_key}"
    grund = "keine Antwort innerhalb der Wiederholungen"
    for _ in range(tries):
        try:
            data = http_get(url, token)
            ps = data.get("projectStatus", {}) or {}
            st = ps.get("status")
            if st and st != "NONE":
                return st, "", ps.get("conditions", []) or []
            grund = "SonarQube meldet NONE — noch keine Analyse verrechnet"
            # NONE = noch keine Analyse verrechnet -> kurz warten und erneut
        except urllib.error.HTTPError as e:
            if e.code in (404,):
                return "NONE", f"HTTP 404 — Projekt {project_key} in SonarQube unbekannt", []
            if e.code in (401, 403):
                # NICHT wiederholen: das heilt nicht von selbst. 403 an dieser Kante heisst in
                # aller Regel "User-Agent geblockt" (siehe http_get), 401 "Token ungueltig".
                return "UNKNOWN", (f"HTTP {e.code} — Abfrage abgewiesen, nicht ausgefallen. "
                                   f"Verdacht: Cloudflare-Kante (User-Agent) oder Token "
                                   f"ungueltig. Pruefen mit: curl -u '<token>:' '{url}'"), []
            grund = f"HTTP {e.code} {e.reason}"
        except Exception as e:  # noqa: BLE001 - Ursache soll sichtbar werden, nicht verschwinden
            grund = f"{type(e).__name__}: {e}"
        time.sleep(delay)
    return "UNKNOWN", grund, []


def owasp_high_cves(owasp_json_path, threshold):
    """(count, top_beschreibung): Anzahl Abhängigkeiten mit CVSS >= threshold."""
    if not owasp_json_path or not os.path.exists(owasp_json_path):
        return None, None  # None = Scan nicht verfügbar (löst KEINEN Breach aus)
    try:
        data = json.load(open(owasp_json_path, encoding="utf-8"))
    except Exception:
        return None, None
    hits = []
    for dep in data.get("dependencies", []):
        worst = 0.0
        worst_cve = None
        for v in dep.get("vulnerabilities", []) or []:
            score = 0.0
            for key in ("cvssv3", "cvssv2"):
                node = v.get(key) or {}
                s = node.get("baseScore") or node.get("score")
                if s:
                    try:
                        score = max(score, float(s))
                    except (TypeError, ValueError):
                        pass
            if score >= threshold and score > worst:
                worst, worst_cve = score, v.get("name")
        if worst >= threshold:
            hits.append((dep.get("fileName", "?"), worst, worst_cve))
    hits.sort(key=lambda h: h[1], reverse=True)
    if not hits:
        return 0, None
    top = hits[0]
    return len(hits), f"höchste CVSS {top[1]} ({top[2]} in {top[0]})"


def esc(v):
    """Minimal-Escape für java.util.Properties-Werte (einzeilig)."""
    return str(v).replace("\\", "\\\\").replace("\n", " ").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--project-key", required=True)
    ap.add_argument("--sonar-url", required=True)
    ap.add_argument("--sonar-token", default=os.environ.get("SONAR_TOKEN", ""))
    ap.add_argument("--report-task", default="")
    ap.add_argument("--owasp-json", default="")
    ap.add_argument("--dashboard-url", default="")
    ap.add_argument("--cvss-threshold", type=float, default=7.0)
    ap.add_argument("--now", default="", help="ISO-Zeitstempel (sonst wird er hier gesetzt)")
    args = ap.parse_args()

    now = args.now or datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    token = args.sonar_token

    wait_for_ce_task(args.report_task, token)
    gate, gate_grund, gate_conds = sonar_gate_status(args.sonar_url, args.project_key, token)
    cve_count, cve_top = owasp_high_cves(args.owasp_json, args.cvss_threshold)

    sonar_dash = f"{args.sonar_url.rstrip('/')}/dashboard?id={args.project_key}"
    breaches = []
    if gate == "ERROR":
        # KARTE 1177: Das Gate `plaintext` in SonarQube besteht ausschliesslich aus New-Code-
        # Bedingungen (new_violations, new_coverage, new_duplicated_lines_density,
        # new_security_hotspots_reviewed — nachgesehen am 10.09.2026 an
        # /api/qualitygates/show, alle vier isCaycCondition). Ein ERROR hier heisst deshalb
        # "in NEUEM Code", nie "Altlast" — das ist Daniels Entscheid vom 10.09.2026
        # ("nur neue Befunde scharf") und der Grund, warum die rund 3858 Altbefunde hier
        # nichts ausloesen. Wer dem Gate eine Nicht-New-Code-Bedingung hinzufuegt, hebelt
        # diesen Entscheid aus, ohne dass es hier auffaellt.
        verletzt = ", ".join(
            f"{c.get('metricKey')}={c.get('actualValue')} "
            f"(Schwelle {c.get('comparator')} {c.get('errorThreshold')})"
            for c in gate_conds if c.get("status") == "ERROR"
        )
        breaches.append(f"SonarQube Quality Gate = ERROR in NEUEM Code"
                        + (f": {verletzt}" if verletzt else "")
                        + f" — Details: {sonar_dash}")
    if gate == "UNKNOWN":
        # Ein nicht messbares Gate ist kein bestandenes Gate. Vorher war genau das der Fall:
        # UNKNOWN loeste nichts aus, also stand das Gate gruen, obwohl es nichts wusste.
        breaches.append(f"SonarQube Quality Gate NICHT MESSBAR — {gate_grund}. "
                        f"Ein gruenes Gate ohne Messung ist kein Beleg.")
    if cve_count:  # None (kein Scan) und 0 lösen nichts aus
        breaches.append(f"OWASP: {cve_count} Abhängigkeit(en) mit CVSS>={args.cvss_threshold} "
                        f"({cve_top})")

    status = "BREACHED" if breaches else "OK"

    lines = [
        "# Automatisch erzeugt von quality/quality-gate.py (wöchentliche Voll-Analyse).",
        "# status=BREACHED => QualityGateTest schlägt fehl (nightly/PR/lokal), Pushover ging raus.",
        "# Wird beim nächsten wöchentlichen Lauf neu bewertet; nach Fix wieder status=OK.",
        f"status={status}",
        f"checked={now}",
        f"sonar.status={gate}",
        f"sonar.url={esc(sonar_dash)}",
        # KARTE 1177: Die Einzelwerte gehoeren in die Datei, nicht nur ins Step-Log. Sonst ist
        # an einem `sonar.status=ERROR` nicht ablesbar, ob NEUE Befunde dazugekommen sind
        # (new_violations) oder ob bloss die Abdeckung des neuen Codes unter der Schwelle liegt
        # (new_coverage) — das sind zwei voellig verschiedene Aufgaben.
        f"sonar.new_code.gemessen={'ja' if gate_conds else 'nein'}",
    ]
    for c in gate_conds:
        # Getrennte Schluessel, KEIN `#` im Wert: java.util.Properties behandelt `#` nur am
        # Zeilenanfang als Kommentar. Mitten in der Zeile wuerde es Teil des Wertes und
        # `sonar.new_violations` liesse sich nicht mehr als Zahl lesen.
        metrik = esc(c.get("metricKey", "?"))
        lines.append(f"sonar.{metrik}={esc(c.get('actualValue', 'n/a'))}")
        lines.append(f"sonar.{metrik}.status={esc(c.get('status', '?'))}")
        lines.append(f"sonar.{metrik}.schwelle="
                     f"{esc(c.get('comparator', ''))} {esc(c.get('errorThreshold', ''))}")
    if gate_grund:
        lines.append(f"sonar.grund={esc(gate_grund)}")
    lines += [
        f"cve.high.count={cve_count if cve_count is not None else 'n/a'}",
        f"cve.threshold={args.cvss_threshold}",
        f"dashboard.url={esc(args.dashboard_url)}",
        f"breach.count={len(breaches)}",
    ]
    for i, b in enumerate(breaches, 1):
        lines.append(f"breach.{i}={esc(b)}")

    out_dir = os.path.join(args.repo, "quality")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "quality-gate.properties")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"Quality-Gate: {status} (sonar={gate}, cve>={args.cvss_threshold}={cve_count})")
    print(f"Geschrieben: {out_path}")
    for b in breaches:
        print(f"  ! {b}")
    sys.exit(10 if status == "BREACHED" else 0)


if __name__ == "__main__":
    main()
