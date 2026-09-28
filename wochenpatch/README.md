# wochenpatch — woechentlicher Patch-Release aller Anwendungen (Karte 1340)

Auftrag Daniel, 28.09.2026: den an diesem Tag von Hand gefahrenen Ablauf (Renovate-Updates,
bauen, testen, releasen, deployen) jeden Sonntag automatisch per Woodpecker. SonarQube gehoert
nicht dazu.

## Dateien

| Datei | Zweck |
|---|---|
| `lauf.sh` | Ablauf ueber alle Repos, Modus `pr` (Vorgabe) oder `ausrollen` |
| `maven-patch.sh` | Patch-Updates per versions-maven-plugin (nur dritte Stelle), optional root-/app-Version |
| `owasp-tote-suppressionen.sh` | entfernt gepinnte OWASP-Suppressionen, deren Version nicht mehr auf dem Klassenpfad liegt |
| `projectmind-patch.sh` | `cargo update` + `pnpm update` mit Tests |
| `lib.sh` | Warten auf PR-Pruefungen, Paket-Repo, `/nosec/version` |
| `woodpecker-wochenpatch.yml.vorlage` | der Job, noch nicht scharf (siehe unten) |
| `../test-wochenpatch.sh` | Testharnisch ohne Netz (mvn-Attrappe) |

## Reihenfolge im Modus `ausrollen`

root → (Paket-Repo abwarten) → app mit neuer root-Version → (Paket-Repo) → guild mit neuer
root- und app-Version → schuetu → iot (gemergt mit `[skip ci]`, **kein** Rollout) → ProjectMind
(PR, Release-PR, Cargo.lock nachziehen, Tag). fwtool ist seit 23.09.2026 archiviert und fehlt.

## Scharfschalten (in dieser Reihenfolge)

1. `plaintext-scripts` in Woodpecker aktivieren, Timeout auf mehrere Stunden.
2. Secrets am Repo anlegen: `wochenpatch_gh_token` (PR, Merge, Workflow-Dispatch in allen
   Anwendungs-Repos), `pushover_app_token`, `pushover_user_key`.
3. Cron `wochenpatch` anlegen (Sonntag).
4. Erst jetzt `woodpecker-wochenpatch.yml.vorlage` nach `.woodpecker/wochenpatch.yml` kopieren.
5. Ersten Lauf manuell im Modus `pr`. `ausrollen` nur mit Daniels Freigabe.

## Bekannte Grenzen

- Der Deploy-Slot (Karte 413, Nextcloud Deck) wird nicht belegt; der Job arbeitet die Repos
  strikt nacheinander ab und merged nur, wenn kein fremder PR offen ist.
- Majors bleiben liegen und stehen weiter im Renovate-Dashboard.
