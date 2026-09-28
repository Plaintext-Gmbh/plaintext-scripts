#!/usr/bin/env bash
# wochenpatch/maven-patch.sh — zieht in einem Maven-Repo alle PATCH-Updates nach (Karte 1340).
#
#   maven-patch.sh <repo-verzeichnis> [--parent <root-version>] [--app <app-version>]
#
# Was es tut:
#   1. versions:update-properties und versions:use-latest-releases, beide mit
#      allowMajorUpdates=false UND allowMinorUpdates=false — nur der dritte Stellenteil springt.
#      Eigene Artefakte (ch.plaintext:*, alle plaintext-*-Properties) bleiben unberuehrt: deren
#      Version setzt der Aufrufer ausdruecklich mit --parent/--app.
#   2. Mehrfach, bis sich nichts mehr aendert: das Plugin zieht je Lauf nicht immer alles
#      (gemessen am 28.09.2026 in root: der zweite Lauf fand jackson/postgresql, der erste nicht).
#   3. Optional den plaintext-root-Parent und <plaintext-root.version> (--parent) sowie
#      <plaintext-app.version> (--app, nur guild).
#
# Warum ein Plugin und keine Liste: Am 28.09.2026 wurden die Versionen von Hand aus dem
# Renovate-Dashboard uebertragen — jackson 3.1.7 und postgresql 42.7.13 gingen dabei verloren.
#
# Ausgabe auf stdout: eine Zeile je geaenderter Version (fuer Commit und Bericht). Ende 0 auch
# ohne Aenderung; der Aufrufer entscheidet am git diff.
set -euo pipefail
DIR="${1:?Repo-Verzeichnis fehlt}"; shift
PARENT=""; APP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --parent) PARENT="$2"; shift 2 ;;
        --app)    APP="$2"; shift 2 ;;
        *) echo "unbekannte Option: $1" >&2; exit 2 ;;
    esac
done
cd "$DIR"
V="org.codehaus.mojo:versions-maven-plugin:${WP_VERSIONS_PLUGIN:-2.21.0}"
AUSNAHMEN='plaintext-root.version,plaintext-app.version,plaintext-root-interfaces.version,plaintext.version'
GEMEINSAM=(-q -B -DgenerateBackupPoms=false -DallowMajorUpdates=false -DallowMinorUpdates=false
           "-Dmaven.version.ignore=.*-(alpha|beta|rc|RC|M|milestone)[0-9.-]*,.*-SNAPSHOT")

for runde in 1 2 3; do
    vorher="$(git diff --stat | tail -1)"
    mvn "${GEMEINSAM[@]}" "$V:update-properties" "-DexcludeProperties=$AUSNAHMEN" >&2
    mvn "${GEMEINSAM[@]}" "$V:use-latest-releases" '-Dexcludes=ch.plaintext:*' >&2
    [ "$(git diff --stat | tail -1)" = "$vorher" ] && break
    echo "Runde $runde hat etwas geaendert, noch eine" >&2
done

if [ -n "$PARENT" ]; then
    # Nur der Parent plaintext-root-parent, nicht der Spring-Boot-Parent in root selbst.
    python3 - "$PARENT" <<'PY'
import re,sys,glob
neu=sys.argv[1]
for p in ['pom.xml']:
    t=open(p,encoding='utf-8').read()
    t=re.sub(r'(<artifactId>plaintext-root-parent</artifactId>\s*<version>)[^<]+(</version>)',
             r'\g<1>'+neu+r'\2',t,count=1)
    t=re.sub(r'<plaintext-root.version>[^<]+</plaintext-root.version>',
             '<plaintext-root.version>'+neu+'</plaintext-root.version>',t)
    open(p,'w',encoding='utf-8').write(t)
PY
fi
if [ -n "$APP" ]; then
    sed -i "s|<plaintext-app.version>[^<]*</plaintext-app.version>|<plaintext-app.version>$APP</plaintext-app.version>|" pom.xml
fi

# Zusammenfassung: alte -> neue Version je geaenderter Zeile
git diff -U0 -- '*pom.xml' .mvn/extensions.xml 2>/dev/null | python3 -c '
import re,sys
alt={}
for z in sys.stdin:
    m=re.match(r"^([-+])\s*<([A-Za-z0-9._-]+)>([^<]+)</\2>",z)
    if not m: continue
    if m.group(1)=="-": alt[m.group(2)]=m.group(3)
    elif m.group(2) in alt: print(f"{m.group(2)} {alt.pop(m.group(2))} -> {m.group(3)}")
' | sort -u
