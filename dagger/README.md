# Plaintext Dagger Build Module (PoC)

Reusable Dagger module für den shared Plaintext-Build.

## Status

PoC-Stand: `build()` funktioniert end-to-end.

## Verwendung

```bash
# Aus einem Plaintext-Repo (z.B. plaintext-app):
export MVN_PAT=$(bw get password plaintext-platform-github-runner-ghcr-pull-pat)

dagger -m github.com/Plaintext-Gmbh/plaintext-scripts/dagger@master call \
  build \
  --src=. \
  --java-version=25 \
  --coverage=false \
  --skip-tests=true \
  --threads=4 \
  --github-actor=daniel-marthaler \
  --github-token=env:MVN_PAT \
  stdout
```

Lokal identisch wie in CI.

## Funktionen

| Function | Status | Beschreibung |
|----------|--------|--------------|
| `build`  | ✓ | `mvn clean package -B -T N` mit Maven-Cache + GH-Packages-Auth |
| `artifacts` | ✓ | Wie build, returns Directory |
| `test`   | TODO | `mvn verify` + Postgres-Service |
| `sonar`  | TODO | SonarQube Analysis |
| `deploy` | TODO | SSH-deploy |
| `verify` | TODO | HTTP version-check |

## Entwicklung

```bash
cd dagger
dagger develop   # Regenerate bindings nach Java-Änderungen
dagger functions # Listet exposed functions
dagger call <fn> --help
```
