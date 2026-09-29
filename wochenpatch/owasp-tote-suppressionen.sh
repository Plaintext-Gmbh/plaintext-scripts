#!/usr/bin/env bash
# wochenpatch/owasp-tote-suppressionen.sh — entfernt OWASP-Suppressionen, die auf eine exakte
# Version gepinnt sind, die nicht mehr auf dem Klassenpfad liegt (Karte 1340).
#
#   owasp-tote-suppressionen.sh <repo-verzeichnis>
#
# Anlass (28.09.2026, Karte 1338): Spring Boot 4.1.0 -> 4.1.1 hob micrometer 1.17.0 -> 1.17.1.
# Die Suppression `pkg:maven/io.micrometer/micrometer-registry-prometheus@1.17.0` griff nicht
# mehr, PlaintextOwaspSuppressionsTest.keineWirkungsloseSuppression wurde rot — in root und in
# jedem Kind. Genau so ist die Suppression gedacht ("bis zum Boot-Patch"), das Entfernen ist also
# der vorgesehene Schritt; die Bewertung des neuen Stands macht der naechste OWASP-Lauf.
#
# Nur EXAKT gepinnte Eintraege (<packageUrl>pkg:maven/g/a@v</packageUrl>, ohne regex) werden
# angefasst. Offene Bereiche (regex="true", z. B. mxparser@.*) laufen nie ab und bleiben.
# Ausgabe: je entferntem Eintrag eine Zeile "g:a:v".
set -euo pipefail
DIR="${1:?Repo-Verzeichnis fehlt}"
DATEI="$DIR/quality/owasp-suppressions.xml"
[ -f "$DATEI" ] || exit 0
LISTE="$(mktemp)"; trap 'rm -f "$LISTE"' EXIT
# test-compile im selben Aufruf: sonst loest dependency:list die Geschwistermodule des Reaktors
# (x.y.z-SNAPSHOT) nicht auf und bricht ab (gemessen 28.09.2026 an plaintext-root-common).
( cd "$DIR" && mvn -q -B -DskipTests -Dmaven.build.cache.enabled=false test-compile dependency:list \
      -DoutputFile="$LISTE" -DappendOutput=true -Dmdep.outputScope=false -DincludeScope=test >&2 )
python3 - "$DATEI" "$LISTE" "${WP_DATUM:-$(date +%Y-%m-%d)}" <<'PY'
import re,sys
datei,liste,datum=sys.argv[1:4]
vorhanden=set()
for z in open(liste,encoding='utf-8',errors='ignore'):
    m=re.match(r'\s*([^:\s]+):([^:\s]+):[^:\s]+:(?:[^:\s]+:)?([^:\s]+)',z)
    if m: vorhanden.add((m.group(1),m.group(2),m.group(3)))
t=open(datei,encoding='utf-8').read()
tot=[]
for block in re.findall(r'[ \t]*<suppress>.*?</suppress>\n?',t,re.S):
    m=re.search(r'<packageUrl>pkg:maven/([^/<]+)/([^@<]+)@([^<]+)</packageUrl>',block)
    if not m or 'regex="true"' in block: continue
    g,a,v=m.groups()
    if (g,a,v) not in vorhanden:
        t=t.replace(block,'',1); tot.append(f'{g}:{a}:{v}')
if tot:
    hinweis=('    <!-- ENTFERNT '+datum+' (wochenpatch): '+', '.join(tot)+' — die gepinnte Version liegt\n'
             '         nicht mehr auf dem Klassenpfad (PlaintextOwaspSuppressionsTest). Den neuen Stand\n'
             '         bewertet der naechste OWASP-Lauf. -->\n')
    t=t.replace('</suppressions>',hinweis+'</suppressions>',1)
    open(datei,'w',encoding='utf-8').write(t)
print('\n'.join(tot))
PY
