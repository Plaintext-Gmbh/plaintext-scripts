#!/bin/bash
# Zero-downtime M3-Migration einer blue-green-App auf der NAS. Idempotent-ish.
set -e
APP=$1; NAS=mad@192.100.0.1; DP=/volume1/docker/$APP
echo "=== [$APP] 1. Jars platzieren (aus laufendem prod-Container) ==="
ssh -o ConnectTimeout=8 $NAS "PC=\$(sudo docker ps --format '{{.Names}}'|grep -E '$APP-prod-(blue|green)'|head -1); echo src=\$PC; sudo docker cp \"\$PC:/app/app.jar\" /tmp/mjar_$APP; sudo docker run --rm -v $DP:/dp -v /tmp:/t alpine sh -c 'mkdir -p /dp/jars/staging /dp/jars/int-blue /dp/jars/int-green /dp/jars/prod-blue /dp/jars/prod-green; for d in staging int-blue int-green prod-blue prod-green; do cp -f /t/mjar_$APP /dp/jars/\$d/app.jar; done; chmod 644 /dp/jars/*/app.jar; rm -f /t/mjar_$APP'"
echo "=== [$APP] 2. Compose holen + format-erhaltend transformieren ==="
ssh -o ConnectTimeout=8 $NAS "cat $DP/docker-compose.yaml" > /tmp/$APP-c.yaml
python3 /tmp/m3transform.py $APP $DP /tmp/$APP-c.yaml
python3 -c "import yaml;yaml.safe_load(open('/tmp/$APP-c.yaml.m3'))"
RT=$(grep -c "image: plaintext-runtime:jre25" /tmp/$APP-c.yaml.m3); JV=$(grep -c "app.jar:/app/app.jar:ro" /tmp/$APP-c.yaml.m3)
echo "  runtime-images=$RT jar-volumes=$JV (erwartet 4/4)"
[ "$RT" = "4" ] && [ "$JV" = "4" ] || { echo "✗ TRANSFORM-FEHLER"; exit 1; }
echo "=== [$APP] 3. Push (Backup) + INT recreate ==="
cat /tmp/$APP-c.yaml.m3 | ssh -o ConnectTimeout=8 $NAS "cd $DP; cp docker-compose.yaml docker-compose.yaml.pre-m3-\$(date +%y%m%d_%H%M); cat > dc.m3; mv -f dc.m3 docker-compose.yaml; sudo docker compose up -d --no-deps --force-recreate int-blue int-green >/dev/null 2>&1; echo INT-recreated"
echo "=== [$APP] 4. PROD zero-downtime dance (inaktiven Slot zuerst) ==="
ssh -o ConnectTimeout=8 $NAS "set -e; cd $DP; NG=$APP-nginx; CD=nginx/conf.d/prod-upstream.conf; T=nginx/templates
wh(){ for i in \$(seq 1 14); do h=\$(sudo docker inspect -f '{{.State.Health.Status}}' $APP-\$1 2>/dev/null); [ \"\$h\" = healthy ] && { echo \"  \$1 healthy\"; return 0; }; sleep 8; done; echo \"  ✗ \$1 nicht healthy (\$h)\"; return 1; }
sw(){ cp \$CD /tmp/pu_$APP.bak; cp \$T/prod-\$1.conf \$CD; if sudo docker exec \$NG nginx -t >/dev/null 2>&1; then echo \$1>active-prod; sudo docker exec \$NG nginx -s reload; echo \"  nginx → \$1\"; else cp /tmp/pu_$APP.bak \$CD; echo '  ✗ nginx -t FAIL, revert'; return 1; fi; }
A=\$(cat active-prod); I=\$([ \"\$A\" = green ] && echo blue || echo green); echo \"  active=\$A inactive=\$I\"
sudo docker compose up -d --no-deps --force-recreate prod-\$I >/dev/null 2>&1; wh prod-\$I; sw \$I
sudo docker compose up -d --no-deps --force-recreate prod-\$A >/dev/null 2>&1; wh prod-\$A; sw \$A
echo '  FINAL active-prod:' \$(cat active-prod); sudo docker ps --format '{{.Names}} | {{.Image}} | {{.Status}}'|grep -E \"$APP-(int|prod)-(blue|green)\"|sort"
echo "=== [$APP] ✓ M3-Migration fertig ==="
