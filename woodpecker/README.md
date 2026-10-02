# Woodpecker-Vorlagen

Dateien zum Kopieren in andere Repos. Nichts hier wird in plaintext-scripts selbst ausgefuehrt
(die eigenen Pipelines stehen unter `.woodpecker/`).

## `sidecar-image.yml`: Sidecar-Image in die NAS-Registry

Karte 1401, Epic 1399. Baut das `Dockerfile` im Wurzelverzeichnis eines Repos
`plaintext-sidecar-<name>` und pusht es nach `127.0.0.1:6666/plaintext-sidecar-<name>` mit den
Tags `<commit-sha>` und `latest`. Bei einem Pull Request wird nur gebaut.

Die Registry ist `registry:3` auf dem NAS (`plaintext-dockercompose/tri/registry`), nur auf
dem Loopback des NAS erreichbar. Gebaut und gepusht wird ueber den Docker-Socket vom
Host-Daemon, deshalb reicht `127.0.0.1` ohne TLS.

### So baut ein neues Sidecar-Repo in die NAS-Registry

1. Repo privat anlegen: `gh repo create Plaintext-Gmbh/plaintext-sidecar-<name> --private`,
   Standardzweig `master` (oder `main`).
2. `Dockerfile` ins Wurzelverzeichnis, Basis per Digest gepinnt, Dienst ohne root, mit
   `HEALTHCHECK` auf `/.well-known/plaintext-sidecar`.
3. Diese Vorlage als `.woodpecker/image.yml` ins Repo kopieren, unveraendert.
4. In Woodpecker (ci.plaintext.ch) das Repo aktivieren und unter *Settings, Project* den
   Haken *Trusted: volumes* setzen. Das darf nur ein Woodpecker-Admin. Ohne den Haken
   lehnt Woodpecker den Socket-Mount ab.
5. Nichts weiter: die Org-Secrets `nas_registry_user` und `nas_registry_password` gelten fuer
   alle Repos der Org, aber nur bei `push` und `manual`. Ein Pull Request sieht sie nicht.
6. Auf `master` pushen. Der Schritt `bauen-und-pushen` endet mit
   `Gepusht - 127.0.0.1:6666/<repo>:<sha> und ...:latest`.
7. Im Compose-Projekt auf dem NAS: `image: 127.0.0.1:6666/plaintext-sidecar-<name>:latest`
   (oder der SHA-Tag, wenn die Version fest sein soll). Der NAS-Daemon ist als root bereits
   angemeldet.

### Sicherheit

Der Socket-Mount macht jeden Schritt dieser Pipeline zu root auf dem NAS. Wer in ein Repo mit
*Trusted: volumes* pushen darf, hat damit den NAS. Das gilt heute schon fuer app, guild, iot,
root, schuetu und fwtool und ist der Grund, warum der Haken je Repo von Hand gesetzt wird.
Die Vorlage selbst enthaelt keine Geheimnisse, nur die Namen der Secrets.
