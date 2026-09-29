#!/usr/bin/env bash
# Testharnisch fuer wochenpatch/ (Karte 1340).
#
# Prueft ohne Netz und ohne echten Maven-Lauf (mvn wird durch eine Attrappe ersetzt):
#   1. Syntax aller wochenpatch-Skripte (bash -n).
#   2. owasp-tote-suppressionen.sh entfernt GENAU die exakt gepinnten Eintraege, deren Version
#      nicht auf dem Klassenpfad liegt — und laesst Eintraege mit vorhandener Version sowie
#      offene regex-Bereiche stehen (Positiv- und Negativkontrolle, Fall vom 28.09.2026).
#   3. maven-patch.sh meldet eine von der Attrappe geaenderte Version als "alt -> neu" und setzt
#      mit --parent den plaintext-root-parent UND <plaintext-root.version>. Patch und Minor werden
#      genommen, Major, Datums- und Kalenderversionen zurueckgenommen (Entscheid 29.09.2026).
#   4. freigabe.sh: ein manueller Lauf ohne Variable tut nichts, cron heisst "ausrollen".
#   5. deploy_laeuft_nicht erkennt einen laufenden master-Lauf (Positivkontrolle) und meldet
#      "nicht pruefbar" ohne Token.
#   6. lauf.sh im Modus "trocken" gegen lokale Repos (gh/curl-Attrappen): Bericht je Repo, KEIN
#      Push, KEIN PR, KEIN Merge — Gegenprobe: derselbe Aufbau im Modus "pr" pusht und eroeffnet.
#
# Aufruf:  ./test-wochenpatch.sh
set -u
HIER="$(cd "$(dirname "$0")" && pwd)"
ARBEIT="$(mktemp -d)"; trap '[ -n "${BEHALTEN:-}" ] || rm -rf "$ARBEIT"' EXIT
FEHLER=0
ok()   { echo "ok   $*"; }
fail() { echo "FAIL $*"; FEHLER=$((FEHLER + 1)); }

# 1. Syntax
for s in "$HIER"/wochenpatch/*.sh; do
    bash -n "$s" && ok "bash -n $(basename "$s")" || fail "bash -n $(basename "$s")"
done

# mvn-Attrappe: dependency:list schreibt eine feste Liste, versions:* hebt joda-time an.
mkdir -p "$ARBEIT/bin"
cat > "$ARBEIT/bin/mvn" <<'MOCK'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -DoutputFile=*) f="${a#-DoutputFile=}"
       printf '   io.micrometer:micrometer-registry-prometheus:jar:1.17.1\n   org.eclipse.angus:angus-activation:jar:2.0.3\n' >> "$f" ;;
    -DallowM*) echo "$a" >> "${MVN_ARGS_LOG:-/dev/null}" ;;
    *update-properties) sed -i -e 's|<joda-time.version>2.14.3<|<joda-time.version>2.14.4<|' \
        -e 's|<minor.version>1.2.0<|<minor.version>1.3.0<|' -e 's|<major.version>3.1.0<|<major.version>4.0.0<|' \
        -e 's|<datum.version>20240101<|<datum.version>20250101<|' -e 's|<kalender.version>2024.1.0<|<kalender.version>2024.2.0<|' pom.xml ;;
  esac
done
exit 0
MOCK
chmod +x "$ARBEIT/bin/mvn"
export PATH="$ARBEIT/bin:$PATH"

# 2. OWASP
R="$ARBEIT/repo"; mkdir -p "$R/quality"
cat > "$R/quality/owasp-suppressions.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<suppressions xmlns="https://jeremylong.github.io/DependencyCheck/dependency-suppression.1.3.xsd">
    <suppress>
        <packageUrl regex="true">^pkg:maven/io\.github\.x-stream/mxparser@.*$</packageUrl>
        <cpe>cpe:/a:xstream_project:xstream</cpe>
    </suppress>
    <suppress>
        <packageUrl>pkg:maven/org.eclipse.angus/angus-activation@2.0.3</packageUrl>
        <cve>CVE-2025-7962</cve>
    </suppress>
    <suppress>
        <packageUrl>pkg:maven/io.micrometer/micrometer-registry-prometheus@1.17.0</packageUrl>
        <cve>CVE-2026-42154</cve>
    </suppress>
</suppressions>
XML
aus="$("$HIER/wochenpatch/owasp-tote-suppressionen.sh" "$R" 2>/dev/null)"
D="$R/quality/owasp-suppressions.xml"
[ "$aus" = "io.micrometer:micrometer-registry-prometheus:1.17.0" ] && ok "owasp meldet den toten Eintrag" || fail "owasp Ausgabe: '$aus'"
grep -q 'micrometer-registry-prometheus@1.17.0</packageUrl>' "$D" && fail "owasp: toter Eintrag steht noch" || ok "owasp: toter Eintrag entfernt"
grep -q 'angus-activation@2.0.3' "$D" && ok "owasp: Eintrag mit vorhandener Version bleibt" || fail "owasp: angus entfernt"
grep -q 'mxparser@' "$D" && ok "owasp: regex-Bereich bleibt" || fail "owasp: mxparser entfernt"
grep -q 'ENTFERNT' "$D" && ok "owasp: Vermerk geschrieben" || fail "owasp: kein Vermerk"

# 3. maven-patch
M="$ARBEIT/mrepo"; mkdir -p "$M"
cat > "$M/pom.xml" <<'XML'
<project>
    <parent>
        <groupId>ch.plaintext</groupId>
        <artifactId>plaintext-root-parent</artifactId>
        <version>1.725.0</version>
    </parent>
    <properties>
        <plaintext-root.version>1.725.0</plaintext-root.version>
        <joda-time.version>2.14.3</joda-time.version>
        <minor.version>1.2.0</minor.version>
        <major.version>3.1.0</major.version>
        <datum.version>20240101</datum.version>
        <kalender.version>2024.1.0</kalender.version>
    </properties>
</project>
XML
( cd "$M" && git init -q && git add pom.xml && git -c user.name=t -c user.email=t@t commit -q -m init )
export MVN_ARGS_LOG="$ARBEIT/mvn-args.log"
aus="$("$HIER/wochenpatch/maven-patch.sh" "$M" --parent 1.726.0 2>/dev/null)"
unset MVN_ARGS_LOG
grep -q 'joda-time.version 2.14.3 -> 2.14.4' <<<"$aus" && ok "maven-patch meldet joda-time" || fail "maven-patch Ausgabe: '$aus'"
grep -q '<version>1.726.0</version>' "$M/pom.xml" && ok "maven-patch setzt den Parent" || fail "Parent nicht gesetzt"
grep -q '<plaintext-root.version>1.726.0<' "$M/pom.xml" && ok "maven-patch setzt plaintext-root.version" || fail "plaintext-root.version nicht gesetzt"
grep -qx -- '-DallowMinorUpdates=true' "$ARBEIT/mvn-args.log" && grep -qx -- '-DallowMajorUpdates=false' "$ARBEIT/mvn-args.log" \
    && ! grep -q -- '-DallowMinorUpdates=false' "$ARBEIT/mvn-args.log" \
    && ok "maven-patch: Plugin mit Minor ja, Major nein" || fail "maven-patch Plugin-Schalter: $(sort -u "$ARBEIT/mvn-args.log" | tr '\n' ' ')"
grep -q '<minor.version>1.3.0<' "$M/pom.xml" && grep -q 'minor.version 1.2.0 -> 1.3.0' <<<"$aus" \
    && ok "maven-patch: Minor-Sprung genommen" || fail "maven-patch: Minor fehlt ('$aus')"
grep -q '<major.version>3.1.0<' "$M/pom.xml" && ! grep -q 'major.version' <<<"$aus" \
    && ok "maven-patch: Major-Sprung zurueckgenommen" || fail "maven-patch: Major durchgelassen"
grep -q '<datum.version>20240101<' "$M/pom.xml" && ok "maven-patch: Datumsversion zurueckgenommen" || fail "maven-patch: Datumsversion durchgelassen"
grep -q '<kalender.version>2024.1.0<' "$M/pom.xml" && ok "maven-patch: Kalenderversion zurueckgenommen" || fail "maven-patch: Kalenderversion durchgelassen"

# 4. freigabe.sh
f() { env -i PATH="$PATH" "$@" sh -c '. "$0"; echo "MODUS=$WOCHENPATCH_MODUS"' "$HIER/wochenpatch/freigabe.sh" 2>&1 | tail -1; }
[ "$(f CI_PIPELINE_EVENT=manual)" != "MODUS=" ] && [ "$(f CI_PIPELINE_EVENT=manual | grep -c MODUS=)" = 0 ] \
    && ok "freigabe: manual ohne Variable steigt aus" || fail "freigabe: manual ohne Variable: '$(f CI_PIPELINE_EVENT=manual)'"
[ "$(f CI_PIPELINE_EVENT=manual wochenpatch=trocken)" = "MODUS=trocken" ] && ok "freigabe: manual trocken" || fail "freigabe: manual trocken"
[ "$(f CI_PIPELINE_EVENT=manual wochenpatch=egal | grep -c MODUS=)" = 0 ] && ok "freigabe: unbekannter Wert steigt aus" || fail "freigabe: unbekannter Wert"
[ "$(f CI_PIPELINE_EVENT=cron)" = "MODUS=ausrollen" ] && ok "freigabe: cron = ausrollen" || fail "freigabe: cron"
[ "$(f CI_PIPELINE_EVENT=pull_request | grep -c MODUS=)" = 0 ] && ok "freigabe: pull_request steigt aus" || fail "freigabe: pull_request"

# gh- und curl-Attrappen: gh protokolliert jeden Aufruf, curl spielt Woodpecker-API und /nosec/version.
cat > "$ARBEIT/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") echo 0 ;;
  "pr create") echo "https://github.com/x/y/pull/7" ;;
esac
exit 0
MOCK
cat > "$ARBEIT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  */api/repos/lookup/*) echo '{"id":1}' ;;
  */pipelines*) if [ "${MOCK_LAEUFT:-0}" = 1 ]; then echo '[{"number":5,"branch":"master","event":"push","status":"running"}]'; else echo '[{"number":4,"branch":"master","event":"push","status":"success"}]'; fi ;;
  */nosec/version) echo 1.2.0 ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$ARBEIT/bin/gh" "$ARBEIT/bin/curl"
export GH_LOG="$ARBEIT/gh.log"

# 5. deploy_laeuft_nicht
d() { ( set -euo pipefail; . "$HIER/wochenpatch/lib.sh"; rc=0; deploy_laeuft_nicht 2>/dev/null || rc=$?; echo "$rc" ); }
[ "$(WOODPECKER_TOKEN=x d)" = 0 ] && ok "deploy: Ruhe erkannt" || fail "deploy: Ruhe"
[ "$(WOODPECKER_TOKEN=x MOCK_LAEUFT=1 d)" = 1 ] && ok "deploy: laufender master-Lauf erkannt" || fail "deploy: laufender Lauf nicht erkannt"
[ "$(WOODPECKER_TOKEN='' d)" = 3 ] && ok "deploy: ohne Token nicht pruefbar" || fail "deploy: ohne Token"

# 6. lauf.sh trocken gegen lokale Repos
QUELLE="$ARBEIT/quelle"; mkdir -p "$QUELLE"
for r in plaintext-root plaintext-app plaintext-guild plaintext-schuetu plaintext-iot; do
    w="$ARBEIT/w-$r"; mkdir -p "$w"
    printf '<project>\n  <properties>\n    <joda-time.version>2.14.3</joda-time.version>\n  </properties>\n</project>\n' > "$w/pom.xml"
    ( cd "$w" && git init -q -b master && git add pom.xml \
      && git -c user.name=t -c user.email=t@t commit -q -m "Release version 1.2.0 [skip ci]" \
      && git clone -q --bare . "$QUELLE/$r.git" )
done
lauf() {   # $1 Modus
    : > "$GH_LOG"
    WOCHENPATCH_MODUS="$1" WOCHENPATCH_TEIL=maven WP_GIT_BASIS="$QUELLE" WOODPECKER_TOKEN=x \
    WP_BERICHT="$ARBEIT/bericht-$1.txt" WP_DATUM=2026-10-04 WOCHENPATCH_ARBEIT="$ARBEIT/klon-$1" \
    GH_TOKEN='' CI='' "$HIER/wochenpatch/lauf.sh" >/dev/null 2>"$ARBEIT/lauf-$1.err"
}
lauf trocken && ok "trocken: Lauf endet mit 0" || fail "trocken: Lauf rot ($(tail -3 "$ARBEIT/lauf-trocken.err"))"
B="$ARBEIT/bericht-trocken.txt"
[ "$(grep -c 'wuerde PR' "$B")" = 5 ] && ok "trocken: Bericht fuer alle fuenf Repos" || fail "trocken: $(grep -c 'wuerde PR' "$B") statt 5 Repos im Bericht"
grep -q 'joda-time.version 2.14.3 -> 2.14.4' "$B" && ok "trocken: Aenderung im Bericht" || fail "trocken: Aenderung fehlt"
grep -q 'plaintext-iot: wuerde PR .*\[skip ci\]' "$B" && ok "trocken: iot mit [skip ci]" || fail "trocken: iot ohne [skip ci]"
grep -q 'Deploy-Lage: kein offener Lauf' "$B" && ok "trocken: Deploy-Lage geprueft" || fail "trocken: Deploy-Lage fehlt"
grep -q -E 'gh pr (create|merge)|gh workflow' "$GH_LOG" && fail "trocken: gh schreibt ($(grep -E 'create|merge|workflow' "$GH_LOG" | head -1))" || ok "trocken: kein PR, kein Merge"
[ -z "$(git -C "$QUELLE/plaintext-app.git" branch --list 'wochenpatch/*')" ] && ok "trocken: nichts gepusht" || fail "trocken: Zweig gepusht"
# Gegenprobe: im Modus pr sehen dieselben Attrappen den PR und den Push
lauf pr && grep -q 'gh pr create' "$GH_LOG" && ok "Gegenprobe pr: PR eroeffnet" || fail "Gegenprobe pr: kein PR ($(tail -3 "$ARBEIT/lauf-pr.err"))"
[ -n "$(git -C "$QUELLE/plaintext-app.git" branch --list 'wochenpatch/*')" ] && ok "Gegenprobe pr: Zweig gepusht" || fail "Gegenprobe pr: nichts gepusht"
grep -q 'gh pr merge' "$GH_LOG" && fail "Gegenprobe pr: Modus pr merged" || ok "Gegenprobe pr: kein Merge"

echo; [ "$FEHLER" = 0 ] && echo "ALLE TESTS GRUEN" || echo "$FEHLER TEST(S) ROT"
exit "$FEHLER"
