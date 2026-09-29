#!/usr/bin/env bash
# wochenpatch/maven-patch.sh — zieht in einem Maven-Repo alle PATCH- und MINOR-Updates nach
# (Karte 1340; Entscheid Daniel 29.09.2026: Patch und Minor automatisch, Major nie).
#
#   maven-patch.sh <repo-verzeichnis> [--parent <root-version>] [--app <app-version>]
#
# Was es tut:
#   1. versions:update-properties und versions:use-latest-releases, beide mit
#      allowMajorUpdates=false und allowMinorUpdates=true — die erste Stelle bleibt, zweite und
#      dritte duerfen springen.
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
#   4. Nachkontrolle (majorwaechter, laeuft vor Schritt 3): jede geaenderte Version wird gegen die alte geprueft und
#      zurueckgesetzt, wenn die erste Stelle springt ODER eines der beiden kein SemVer-artiges
#      Schema hat (Datum wie 20240101, Kalender wie 2024.1.0 — erste Stelle >= 1000, oder
#      ueberhaupt keine Zahlen-Punkt-Form). Solche Schemata nimmt der Lauf nie automatisch; das
#      Plugin kennt diesen Unterschied nicht und haelt einen neuen Kalenderstand fuer "Minor".
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
GEMEINSAM=(-q -B -DgenerateBackupPoms=false -DallowMajorUpdates=false -DallowMinorUpdates=true
           "-Dmaven.version.ignore=.*-(alpha|beta|rc|RC|M|milestone)[0-9.-]*,.*-SNAPSHOT")

for runde in 1 2 3; do
    vorher="$(git diff --stat | tail -1)"
    mvn "${GEMEINSAM[@]}" "$V:update-properties" "-DexcludeProperties=$AUSNAHMEN" >&2
    mvn "${GEMEINSAM[@]}" "$V:use-latest-releases" '-Dexcludes=ch.plaintext:*' >&2
    [ "$(git diff --stat | tail -1)" = "$vorher" ] && break
    echo "Runde $runde hat etwas geaendert, noch eine" >&2
done

# 4. majorwaechter: verbotene Spruenge zeilengenau zuruecknehmen (auf stderr gemeldet). VOR dem
#    Setzen von --parent/--app: die eigenen Versionen bestimmt der Aufrufer, nicht diese Regel.
git diff -U0 -- '*pom.xml' .mvn/extensions.xml 2>/dev/null | python3 -c '
import re,sys
def erlaubt(alt,neu):
    m1=re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:[.-][0-9A-Za-z.-]+)?$",alt)
    m2=re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:[.-][0-9A-Za-z.-]+)?$",neu)
    if not m1 or not m2: return False                   # kein SemVer-Schema (auch reine Datumszahl)
    if int(m1.group(1))>=1000: return False             # Kalenderversion 2024.x
    return m1.group(1)==m2.group(1)                     # gleiche Major-Stelle
datei=None; zurueck={}
zeilen=sys.stdin.read().splitlines()
i=0
while i<len(zeilen):
    z=zeilen[i]
    if z.startswith("+++ "): datei=z[6:] if z.startswith("+++ b/") else None
    m=re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@",z)
    if m and datei:
        start=int(m.group(1)); minus=[]; plus=[]; i+=1
        while i<len(zeilen) and zeilen[i][:1] in "-+" and not zeilen[i].startswith(("---","+++")):
            (minus if zeilen[i][0]=="-" else plus).append(zeilen[i][1:]); i+=1
        if len(minus)==len(plus):
            for k,(a,b) in enumerate(zip(minus,plus)):
                va=re.search(r">([^<]+)</",a); vb=re.search(r">([^<]+)</",b)
                if va and vb and va.group(1)!=vb.group(1) and not erlaubt(va.group(1).strip(),vb.group(1).strip()):
                    zurueck.setdefault(datei,[]).append((start+k,a))
                    print(f"majorwaechter: {datei}:{start+k} {va.group(1)} -> {vb.group(1)} zurueckgenommen",file=sys.stderr)
        continue
    i+=1
for datei,liste in zurueck.items():
    inhalt=open(datei,encoding="utf-8").read().split("\n")
    for nr,alt in liste: inhalt[nr-1]=alt
    open(datei,"w",encoding="utf-8").write("\n".join(inhalt))
'

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
