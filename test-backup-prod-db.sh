#!/bin/bash
# Testaufbau fuer backup_prod_db() aus tui-build-logic.sh (Karte 955).
# Aufruf: ./test-backup-prod-db.sh tui-build-logic.sh
# ssh und docker sind Attrappen; das ssh-Kommando wird lokal in einer Shell ausgefuehrt, damit
# Umleitung, && und Quoting genau so wirken wie auf dem NAS. Prueft die vier Faelle, die den
# Fehler von Karte 955 ausmachen: echter Dump, fehlender Container, leere Ausgabe trotz rc=0,
# und die Aufbewahrung.
# damit Umleitung, && und Quoting genau so wirken wie auf dem NAS.
BLUE=''; GREEN=''; RED=''; YELLOW=''; NC=''
TESTDIR=$(mktemp -d)
DEPLOY_PATH="$TESTDIR/deploy"; DEPLOY_SERVER=attrappe
IMAGE_NAME=plaintext-app; DB_NAME=plaintext

ssh() { shift; bash -c "$*"; }          # $1 = Server, Rest = Kommando
sudo() { "$@"; }
export -f sudo 2>/dev/null

# docker-Attrappe: Verhalten wird ueber DOCKER_MODUS gesteuert
docker() {
    case "$DOCKER_MODUS" in
        ok)     printf '\x1f\x8b\x08\x00'; head -c 5000 /dev/zero | tr '\0' 'x' ;;  # >1024 Byte
        fehlt)  echo "Error response from daemon: No such container" >&2; return 1 ;;
        leer)   return 0 ;;                                                          # rc=0, nichts
    esac
}
export -f ssh docker 2>/dev/null

# die zu testende Funktion aus der echten Datei holen
eval "$(sed -n '/^backup_prod_db() {/,/^}/p' "$1")"

lauf() {
    local name=$1 modus=$2 erwartet_rc=$3
    export DOCKER_MODUS=$modus
    local pfad; pfad=$(backup_prod_db 2>/dev/null); local rc=$?
    local n; n=$(ls -1 "$DEPLOY_PATH"/backups/backup-*.sql.gz 2>/dev/null | wc -l)
    local urteil="FEHLER"
    [ "$rc" = "$erwartet_rc" ] && urteil="ok"
    printf "  %-34s rc=%s (erwartet %s) -> %-6s Dateien im Ordner: %s\n" "$name" "$rc" "$erwartet_rc" "$urteil" "$n"
}

echo "=== Fall A: alles gut ==="
lauf "echter Dump" ok 0
echo "=== Fall B: Container fehlt (der heutige Fehler) ==="
lauf "docker exec schlaegt fehl" fehlt 1
echo "=== Fall C: rc=0, aber nichts geschrieben ==="
lauf "leere Ausgabe trotz Erfolg" leer 1
echo "=== Fall D: Aufbewahrung (BACKUP_KEEP_DEPLOY=5) ==="
# neun Vorgaenger mit echten, verschiedenen Namen und aufsteigendem Alter anlegen
mkdir -p "$DEPLOY_PATH/backups"
for i in $(seq 9 -1 1); do
    f="$DEPLOY_PATH/backups/backup-26-08-22_09-$(printf '%02d' $i).sql.gz"
    head -c 2000 /dev/zero | tr '\0' 'x' > "$f"
    touch -d "-$i hours" "$f"
done
echo "  vorher im Ordner: $(ls -1 "$DEPLOY_PATH"/backups/backup-*.sql.gz | wc -l)"
export DOCKER_MODUS=ok; backup_prod_db >/dev/null 2>&1
n=$(ls -1 "$DEPLOY_PATH"/backups/backup-*.sql.gz | wc -l)
echo "  nachher im Ordner: $n (erwartet 5)"
echo "  verbliebene (juengste zuerst):"
ls -1t "$DEPLOY_PATH"/backups/backup-*.sql.gz | sed 's|.*/|    |'
rm -rf "$TESTDIR"
