# Gemeinsames Spring-Boot-Runtime-Image für ALLE Plaintext-Apps (M3: Jar im Volume).
#
# Anders als die bisherigen per-App-Images wird das Jar hier NICHT eingebacken, sondern zur
# Laufzeit unter /app/app.jar als Read-only-Volume gemountet. Dadurch entfällt pro Release der
# teure Pfad `docker build` + `docker save | gzip` (~200 MB) + Transfer + `docker load`; deployt
# wird nur noch das ~80-MB-Jar (scp). Das Image ist stabil (selten neu gebaut) und app-agnostisch.
#
# Build/Push: plaintext-scripts/runtime/build-runtime.sh
#
# Karte 807 (15.08.2026): Digest-Pin des Basis-Images. Der Tag sieht mit `25.0.3_9` wie eine
# vollstaendige Version aus, ist aber beweglich — nachgemessen: der lokal vorliegende Stand des
# Tags ist der Index sha256:c707c0d1…, in der Registry steht heute sha256:28db6fdf…, und
# c707c0d1 kommt in 28db6fdf nicht als Plattform-Manifest vor. Zwei verschiedene Inhalte unter
# demselben Tag. Da dieses Image die Basis JEDER Plaintext-App ist (16 laufende Container auf
# plaintext-runtime:jre25), war der Bau bis hierher nicht reproduzierbar.
# Der gepinnte Wert ist der Multi-Arch-Index (enthaelt linux/amd64) — `--platform linux/amd64`
# in build-runtime.sh funktioniert damit unveraendert.
# Aktualisieren: neuen Index-Digest des gewuenschten Tags ermitteln und hier ersetzen; der Tag
# bleibt als Lesehilfe stehen, Rueckweg = `@sha256:…` streichen.
FROM eclipse-temurin:25.0.3_9-jre-alpine@sha256:28db6fdf60e38945e43d840c0333aeaec66c15943070104f7586fd3c9d1665b0

# bash + wget für Healthcheck/Entrypoint
RUN apk add --no-cache bash wget

# App-User mit fixer UID/GID passend zu den NAS-Volume-Rechten
RUN addgroup -g 1000 appgroup && adduser -u 1000 -G appgroup -s /bin/sh -D appuser

WORKDIR /app
RUN mkdir -p /app/data && chown -R appuser:appgroup /app
USER appuser

EXPOSE 8080

# Generischer Readiness/Health-Check (alle Apps sind Spring Boot mit Actuator auf 8080)
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/actuator/health || exit 1

# App-agnostische Defaults; per-App via Compose-`environment` überschreibbar (z. B. JAVA_OPTS-Memory).
ENV JAVA_OPTS="-Xmx512m -Xms256m -Duser.timezone=Europe/Zurich"
ENV SPRING_PROFILES_ACTIVE=prod
ENV TZ=Europe/Zurich

# Das Jar wird als Volume gemountet (NICHT eingebacken): /app/app.jar:ro
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["java $JAVA_OPTS -jar /app/app.jar"]
