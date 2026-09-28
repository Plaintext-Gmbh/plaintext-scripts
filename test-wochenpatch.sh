#!/usr/bin/env bash
# Testharnisch fuer wochenpatch/ (Karte 1340).
#
# Prueft ohne Netz und ohne echten Maven-Lauf (mvn wird durch eine Attrappe ersetzt):
#   1. Syntax aller wochenpatch-Skripte (bash -n).
#   2. owasp-tote-suppressionen.sh entfernt GENAU die exakt gepinnten Eintraege, deren Version
#      nicht auf dem Klassenpfad liegt — und laesst Eintraege mit vorhandener Version sowie
#      offene regex-Bereiche stehen (Positiv- und Negativkontrolle, Fall vom 28.09.2026).
#   3. maven-patch.sh meldet eine von der Attrappe geaenderte Version als "alt -> neu" und setzt
#      mit --parent den plaintext-root-parent UND <plaintext-root.version>.
#
# Aufruf:  ./test-wochenpatch.sh
set -u
HIER="$(cd "$(dirname "$0")" && pwd)"
ARBEIT="$(mktemp -d)"; trap 'rm -rf "$ARBEIT"' EXIT
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
    *update-properties) sed -i 's|<joda-time.version>2.14.3<|<joda-time.version>2.14.4<|' pom.xml ;;
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
    </properties>
</project>
XML
( cd "$M" && git init -q && git add pom.xml && git -c user.name=t -c user.email=t@t commit -q -m init )
aus="$("$HIER/wochenpatch/maven-patch.sh" "$M" --parent 1.726.0 2>/dev/null)"
grep -q 'joda-time.version 2.14.3 -> 2.14.4' <<<"$aus" && ok "maven-patch meldet joda-time" || fail "maven-patch Ausgabe: '$aus'"
grep -q '<version>1.726.0</version>' "$M/pom.xml" && ok "maven-patch setzt den Parent" || fail "Parent nicht gesetzt"
grep -q '<plaintext-root.version>1.726.0<' "$M/pom.xml" && ok "maven-patch setzt plaintext-root.version" || fail "plaintext-root.version nicht gesetzt"

echo; [ "$FEHLER" = 0 ] && echo "ALLE TESTS GRUEN" || echo "$FEHLER TEST(S) ROT"
exit "$FEHLER"
