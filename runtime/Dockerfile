# Gemeinsames Spring-Boot-Runtime-Image für ALLE Plaintext-Apps (M3: Jar im Volume).
#
# Anders als die bisherigen per-App-Images wird das Jar hier NICHT eingebacken, sondern zur
# Laufzeit unter /app/app.jar als Read-only-Volume gemountet. Dadurch entfällt pro Release der
# teure Pfad `docker build` + `docker save | gzip` (~200 MB) + Transfer + `docker load`; deployt
# wird nur noch das ~80-MB-Jar (scp). Das Image ist stabil (selten neu gebaut) und app-agnostisch.
#
# Build/Push: plaintext-scripts/runtime/build-runtime.sh
FROM eclipse-temurin:25.0.3_9-jre-alpine

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
