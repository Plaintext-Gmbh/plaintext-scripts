# wochenpatch — woechentlicher Patch-Release aller Anwendungen (Karte 1340)

Auftrag Daniel, 28.09.2026: den an diesem Tag von Hand gefahrenen Ablauf (Renovate-Updates,
bauen, testen, releasen, deployen) jeden Sonntag automatisch per Woodpecker. SonarQube gehoert
nicht dazu.

## Dateien

| Datei | Zweck |
|---|---|
| `lauf.sh` | Ablauf ueber alle Repos, Modus `trocken` (Vorgabe), `pr` oder `ausrollen` |
| `freigabe.sh` | Woodpecker: cron = `ausrollen`, manual nur mit Variable `wochenpatch` |
| `maven-patch.sh` | Patch- und Minor-Updates per versions-maven-plugin (erste Stelle bleibt, Datums-/Kalenderversionen nie), optional root-/app-Version |
| `owasp-tote-suppressionen.sh` | entfernt gepinnte OWASP-Suppressionen, deren Version nicht mehr auf dem Klassenpfad liegt |
| `projectmind-patch.sh` | `cargo update` + `pnpm update` mit Tests |
| `lib.sh` | Warten auf PR-Pruefungen, Paket-Repo, `/nosec/version`, laufende Deploys (Woodpecker-API) |
| `../.woodpecker/wochenpatch.yml` | der Job (Cron `wochenpatch`, Sonntag 04:07 UTC) |
| `../test-wochenpatch.sh` | Testharnisch ohne Netz (mvn-, gh-, curl-Attrappen, lokale Repos) |

## Auswahl der Updates

Entscheid Daniel, 29.09.2026: **Patch und Minor automatisch, Major nie.**

- Maven: `allowMajorUpdates=false`, `allowMinorUpdates=true`, danach der majorwaechter in
  `maven-patch.sh`: er nimmt jede Aenderung zurueck, deren erste Stelle springt oder deren Schema
  nicht Zahl.Zahl[.Zahl] ist (reine Datumszahl wie `20240101`, Kalenderversion wie `2024.1.0`).
  Vorabversionen (alpha, beta, RC, M, SNAPSHOT) sind ausgeschlossen.
- ProjectMind: `cargo update` und `pnpm update` bleiben in den Bereichen aus `Cargo.toml` bzw.
  `package.json` (`^`: Minor ab 1.0, bei 0.x nur Patch).

## Modi

| Modus | Wirkung |
|---|---|
| `trocken` | Vorflug: klonen, patchen, OWASP, `test-compile`, fremde PRs und Deploy-Lage ansehen, Bericht je Repo. Kein Push, kein PR, kein Merge, kein Pushover. |
| `pr` | je Repo ein PR `wochenpatch/<datum>`, nichts wird gemergt |
| `ausrollen` | wie am 28.09.2026 von Hand, siehe unten. Entscheid Daniel 29.09.2026; der Cron faehrt diesen Modus. |

Von Hand in Woodpecker: *Run pipeline* mit der Variable `wochenpatch = trocken|pr|ausrollen`.
Ohne Variable endet jeder Step sofort gruen (freigabe.sh).

## Reihenfolge im Modus `ausrollen`

root → (Paket-Repo abwarten) → app mit neuer root-Version → (Paket-Repo) → guild mit neuer
root- und app-Version → schuetu → iot (gemergt mit `[skip ci]`, **kein** Rollout) → ProjectMind
(PR, Release-PR, Cargo.lock nachziehen, Tag). fwtool ist seit 23.09.2026 archiviert und fehlt.


**Release fertig** heisst: der Woodpecker-push-Lauf des Commits, aus dem `Release version X`
gebaut wurde, ist `success` (bei failure/killed Abbruch), UND ein Blatt-Jar liegt im Paket-Repo
(root: `plaintext-root-watch`, app: `plaintext-z-kontakte`). Der Parent-POM allein reicht nicht:
im Lauf 10/#7 (29.09.2026) lag `plaintext-root-parent` 1.732.0 schon oben, die Module noch nicht.

**Wiederaufsetzbar:** Hat root (bzw. app) nichts zu patchen, weil ein frueherer Lauf es schon
gemergt und released hat, wird es nicht erneut angefasst; die Kinder folgen der zuletzt
veroeffentlichten Version, sobald deren Release fertig ist. Einfach denselben Lauf nochmals starten.

## Einrichtung in Woodpecker (erledigt 29.09.2026, Karte 1340)

1. `plaintext-scripts` in Woodpecker aktiviert, Timeout hoeher als die 120 min der Apps.
2. Secrets am Repo, Ereignisse nur `cron` und `manual` (das Repo ist oeffentlich):
   `mvn_deploy_token` (GitHub-PAT, Vault `github.mvn-deploy-pat (daniel-marthaler)`),
   `woodpecker_token` (Vault `woodpecker.api-token`), `pushover_app_token` und
   `pushover_user_key` (Vault `Pushover API (motionEye + plaintext-boot CI)`).
3. Cron `wochenpatch`, `7 4 * * 0`, Zweig `master`, eingeschaltet.
4. Erst danach `.woodpecker/wochenpatch.yml` mit den `from_secret`-Zeilen.

## Vorprüfung, Auto-Bumps, Meldung (Karte 1419)

- **Vorprüfung vor root:** Bevor root angefasst wird, liest der Job in allen Repos die offenen PRs.
  Ist irgendwo ein fremder PR offen (weder `renovate/`, noch `wochenpatch/`, noch
  `chore/root-autobump`) oder ist die Deploy-Lage nicht prüfbar, endet `ausrollen` sofort, ohne
  etwas zu verändern, und nennt Repo und PR-Nummern. Am 04.10.2026 war root schon released, als app
  an fremden PRs scheiterte. `trocken` und `pr` schreiben den Befund nur in den Bericht.
- **Auto-Bump-PRs** (`chore/root-autobump`) setzen dieselbe Root-Version wie der Wochenpatch und
  werden in `ausrollen` mit Kommentar geschlossen: einmal nach der Vorprüfung und noch einmal direkt
  vor jedem Merge, weil der root-Release inzwischen neue eröffnet haben kann.
- **Pushover:** Abbruchgrund und `Liegengeblieben: …` stehen vorn, der Text wird unter 1024 Zeichen
  gekürzt (Grenze der Pushover-API), mit Link auf den Woodpecker-Lauf. Der Versand steht im Log
  (`Pushover gesendet …` oder `FEHLER Pushover: rc=…`). Fehlt Skript oder Token, ist das ein
  Fehler: ein sonst gelungener Lauf endet dann mit Exit 4.

## Bekannte Grenzen

- Der Deploy-Slot (Karte 413, Nextcloud Deck) wird nicht belegt — der Job hat keinen Deck-Zugang.
  Ersatz: vor jedem Merge wartet er, bis in keinem Deploy-Repo ein Woodpecker-Lauf auf `master`
  offen ist, arbeitet die Repos strikt nacheinander ab und merged nur ohne fremden offenen PR.
  Ein Agent, der den Slot haelt, aber noch nicht gemergt hat, bleibt damit unsichtbar.
- Rotiert das GitHub-PAT, muss auch das Secret `mvn_deploy_token` an plaintext-scripts neu.
- Majors bleiben liegen und stehen weiter im Renovate-Dashboard.
