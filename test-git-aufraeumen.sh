#!/usr/bin/env bash
# Selbsttest fuer git-aufraeumen: baut ein Wegwerf-Remote samt Klonen und Worktrees auf und prueft,
# dass erledigte Arbeit verschwindet und offene Arbeit bleibt. Kein Netz, kein GitHub (--ohne-github).
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null
TOOL="$(cd "$(dirname "$0")" && pwd)/git-aufraeumen"
FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 — erwartet '$2', war '$3'"; FEHLER=$((FEHLER+1)); fi; }

REMOTE="$T/remote/github.com/TestOrg/demo.git"; mkdir -p "$(dirname "$REMOTE")"; git init -q --bare -b master "$REMOTE"
W="$T/home"; mkdir -p "$W"
git clone -q "$REMOTE" "$W/demo" 2>/dev/null; cd "$W/demo" || exit 1
echo a > a.txt; git add a.txt; git commit -qm init; git push -q origin master
# 1 integriert: normal gemergt
git checkout -qb integriert; echo b > b.txt; git add b.txt; git commit -qm b; git checkout -q master; git merge -q --no-ff integriert -m m; git push -q origin master
# 2 squash: Inhalt per Squash in master, Branch-Historie verschieden
git checkout -qb squash; echo c > c.txt; git add c.txt; git commit -qm c1; echo c2 >> c.txt; git commit -qam c2
git checkout -q master; git merge -q --squash squash; git commit -qm "squash c"; git push -q origin master
# 3 offene Arbeit: eigener Commit, nicht im master
git checkout -qb offen; echo d > d.txt; git add d.txt; git commit -qm d; git checkout -q master
# 4 Worktree, sauber, auf einem integrierten Branch
git branch wt-sauber integriert; git worktree add -q "$W/wt-sauber" wt-sauber
# 5 Worktree mit Aenderungen
git branch wt-dreckig integriert; git worktree add -q "$W/wt-dreckig" wt-dreckig; echo x > "$W/wt-dreckig/neu.txt"
# 6 alte Arbeitskopie (eigener Klon) nur mit master -> darf ganz weg
git clone -q "$REMOTE" "$W/wtalt" 2>/dev/null
# 7 alte Arbeitskopie mit offener Arbeit -> muss bleiben
git clone -q "$REMOTE" "$W/wtoffen" 2>/dev/null; (cd "$W/wtoffen" || exit 1; git checkout -qb eigen; echo e > e.txt; git add e.txt; git commit -qm e)
git remote set-head origin master >/dev/null 2>&1

echo "== Trockenlauf darf nichts aendern"
"$TOOL" --wurzel "$W" --org TestOrg --ohne-github >"$T/trocken.txt" 2>&1
pruefe "Trockenlauf: Branch 'offen' noch da"   "1" "$(git -C "$W/demo" branch --list offen | wc -l | tr -d ' ')"
pruefe "Trockenlauf: Worktree wt-sauber noch da" "yes" "$([ -d "$W/wt-sauber" ] && echo yes || echo no)"
pruefe "Klasse squash = INTEGRIERT-INHALT"     "1" "$(grep -c "'INTEGRIERT-INHALT': 1" "$T/trocken.txt")"
pruefe "offen wird als OFFENE-ARBEIT gemeldet"  "1" "$(grep -cE 'bleibt OFFENE-ARBEIT +TestOrg/demo +offen ' "$T/trocken.txt")"

echo "== Ausfuehren"
"$TOOL" --wurzel "$W" --org TestOrg --ohne-github --ausfuehren >"$T/aus.txt" 2>&1
pruefe "integriert geloescht"            "0" "$(git -C "$W/demo" branch --list integriert | wc -l | tr -d ' ')"
pruefe "squash geloescht (Inhalt drin)"  "0" "$(git -C "$W/demo" branch --list squash | wc -l | tr -d ' ')"
pruefe "offen BLEIBT"                    "1" "$(git -C "$W/demo" branch --list offen | wc -l | tr -d ' ')"
pruefe "sauberer Worktree entfernt"      "no" "$([ -d "$W/wt-sauber" ] && echo yes || echo no)"
pruefe "Worktree mit Aenderung BLEIBT"   "yes" "$([ -f "$W/wt-dreckig/neu.txt" ] && echo yes || echo no)"
pruefe "alte Kopie nur mit master weg"   "no" "$([ -d "$W/wtalt" ] && echo yes || echo no)"
pruefe "alte Kopie mit Arbeit BLEIBT"    "yes" "$([ -d "$W/wtoffen" ] && echo yes || echo no)"
pruefe "Hauptklon steht auf master"      "master" "$(git -C "$W/demo" branch --show-current)"

echo "== Gegenprobe: --auch-offene loescht auch offene Arbeit"
"$TOOL" --wurzel "$W" --org TestOrg --ohne-github --ausfuehren --auch-offene >/dev/null 2>&1
pruefe "mit --auch-offene: offen weg"    "0" "$(git -C "$W/demo" branch --list offen | wc -l | tr -d ' ')"

[ "$FEHLER" -eq 0 ] && echo "ALLE FAELLE OK" || { echo "$FEHLER FEHLER"; exit 1; }
