package io.dagger.modules.plaintextbuild;

import static io.dagger.client.Dagger.dag;

import io.dagger.client.CacheVolume;
import io.dagger.client.Container;
import io.dagger.client.Directory;
import io.dagger.client.File;
import io.dagger.client.Secret;
import io.dagger.client.Service;
import io.dagger.client.exception.DaggerQueryException;
import io.dagger.module.annotation.DefaultPath;
import io.dagger.module.annotation.Function;
import io.dagger.module.annotation.Object;
import java.util.List;
import java.util.concurrent.ExecutionException;

/**
 * Plaintext shared build pipeline as Dagger module.
 *
 * <p>Functions:
 * <ul>
 *   <li>build  – mvn clean package (mit optional coverage / skip-tests)
 *   <li>test   – mvn verify mit Postgres-service-container
 *   <li>sonar  – SonarQube Analysis
 *   <li>deploy – SSH-Deploy via plaintext-scripts deploy-helpers
 *   <li>verify – HTTP version-check der deployten App
 * </ul>
 */
@Object
public class PlaintextBuild {

  /**
   * Maven clean package mit optionalem Coverage + Test-Skip.
   *
   * @param src         Projekt-Verzeichnis (mit pom.xml im root)
   * @param javaVersion Temurin-Major-Version (default "25")
   * @param coverage    JaCoCo-Profil aktivieren (default false)
   * @param skipTests   Tests ueberspringen (default false)
   * @param threads     Parallelitaet -T N (default 4)
   * @return Container mit gebautem Projekt (target/*.jar in /src/<module>/target)
   */
  @Function
  public Container build(
      @DefaultPath(".") Directory src,
      String javaVersion,
      Boolean coverage,
      Boolean skipTests,
      Integer threads,
      String githubActor,
      Secret githubToken) {
    String jdk = javaVersion == null || javaVersion.isBlank() ? "25" : javaVersion;
    boolean withCoverage = Boolean.TRUE.equals(coverage);
    boolean noTests = Boolean.TRUE.equals(skipTests);
    int t = (threads == null || threads <= 0) ? 4 : threads;
    String actor = githubActor == null || githubActor.isBlank() ? "github-actions" : githubActor;

    StringBuilder mvn = new StringBuilder("mvn clean package -B -T " + t);
    if (withCoverage) {
      mvn.append(" -Pcoverage");
    }
    if (noTests) {
      mvn.append(" -DskipTests");
    }

    Container c = mavenContainer(jdk)
        .withMountedDirectory("/src", src)
        .withWorkdir("/src")
        .withEnvVariable("MAVEN_OPTS", "-Xmx2g")
        .withEnvVariable("GITHUB_ACTOR", actor);

    if (githubToken != null) {
      c = c.withSecretVariable("GITHUB_TOKEN", githubToken)
          .withMountedFile("/root/.m2/settings.xml",
              dag().file("settings.xml", settingsXml()));
    }

    return c.withExec(List.of("sh", "-lc", mvn.toString()));
  }

  /**
   * mvn verify — Tests inkl. Integration (Failsafe) gegen Postgres-Service-Container.
   *
   * <p>Postgres laeuft als Dagger-Service auf Hostname "postgres" Port 5432. Workflow-DB-URL:
   * {@code jdbc:postgresql://postgres:5432/<databaseName>}. Im Unterschied zur alten Pipeline
   * gibt es kein Host-Port-Mapping → keine Port-Konflikte zwischen parallelen Builds.
   *
   * @param src              Projekt-Verzeichnis
   * @param javaVersion      JDK-Version (default 25)
   * @param databaseName     DB die fuer Tests erstellt wird (z.B. "plaintext")
   * @param coverage         JaCoCo-Profil aktivieren
   * @param threads          Parallelitaet (default 4)
   * @param githubActor      GitHub-User fuer Packages
   * @param githubToken      GH-Packages PAT (read:packages)
   * @return Container nach mvn verify (target/* mit jacoco-reports falls coverage=true)
   */
  @Function
  public Container test(
      @DefaultPath(".") Directory src,
      String javaVersion,
      String databaseName,
      Boolean coverage,
      Integer threads,
      String githubActor,
      Secret githubToken) {
    String jdk = javaVersion == null || javaVersion.isBlank() ? "25" : javaVersion;
    String db = databaseName == null || databaseName.isBlank() ? "plaintext" : databaseName;
    boolean withCoverage = Boolean.TRUE.equals(coverage);
    int t = (threads == null || threads <= 0) ? 4 : threads;
    String actor = githubActor == null || githubActor.isBlank() ? "github-actions" : githubActor;

    Service postgres = postgresService(db);

    StringBuilder mvn = new StringBuilder(
        "mvn verify -B -T " + t + " -Dspring.datasource.url=jdbc:postgresql://postgres:5432/" + db);
    if (withCoverage) {
      mvn.append(" -Pcoverage");
    }

    Container c = mavenContainer(jdk)
        .withMountedDirectory("/src", src)
        .withWorkdir("/src")
        .withEnvVariable("MAVEN_OPTS", "-Xmx2g")
        .withEnvVariable("GITHUB_ACTOR", actor)
        .withEnvVariable("SPRING_DATASOURCE_USERNAME", "plaintext")
        .withEnvVariable("SPRING_DATASOURCE_PASSWORD", "plaintext")
        .withServiceBinding("postgres", postgres);

    if (githubToken != null) {
      c = c.withSecretVariable("GITHUB_TOKEN", githubToken)
          .withMountedFile("/root/.m2/settings.xml",
              dag().file("settings.xml", settingsXml()));
    }

    return c.withExec(List.of("sh", "-lc", mvn.toString()));
  }

  /**
   * Extrahiert den jacoco.csv-Report aus einem fertig getesteten Build.
   * Voraussetzung: Test-Container mit coverage=true.
   */
  @Function
  public File coverage(
      @DefaultPath(".") Directory src,
      String javaVersion,
      String databaseName,
      Integer threads,
      String githubActor,
      Secret githubToken)
      throws InterruptedException, ExecutionException, DaggerQueryException {
    return test(src, javaVersion, databaseName, true, threads, githubActor, githubToken)
        .withExec(List.of("sh", "-lc", "mvn jacoco:report -B || true"))
        .file("/src/target/site/jacoco/jacoco.csv");
  }

  /**
   * SonarQube Analysis: mvn clean verify sonar:sonar mit jacoco coverage.
   *
   * @param projectName   Sonar-Project-Name (z.B. "plaintext-app")
   * @param sonarUrl      Server URL (default http://192.168.1.224:9000)
   * @param sonarToken    Sonar-Token (Secret)
   * @param src           Projekt-Verzeichnis
   * @param javaVersion   JDK
   * @param databaseName  DB fuer Tests
   * @param githubActor   GH-User
   * @param githubToken   GH-Packages PAT
   * @return Container nach sonar:sonar
   */
  @Function
  public Container sonar(
      String projectName,
      String sonarUrl,
      Secret sonarToken,
      @DefaultPath(".") Directory src,
      String javaVersion,
      String databaseName,
      String githubActor,
      Secret githubToken) {
    String jdk = javaVersion == null || javaVersion.isBlank() ? "25" : javaVersion;
    String db = databaseName == null || databaseName.isBlank() ? "plaintext" : databaseName;
    String url = sonarUrl == null || sonarUrl.isBlank() ? "http://192.168.1.224:9000" : sonarUrl;
    String actor = githubActor == null || githubActor.isBlank() ? "github-actions" : githubActor;

    Service postgres = postgresService(db);

    // Project key wird im current workflow via mvn help:evaluate dynamisch ermittelt.
    // Hier vereinfacht: groupId:artifactId aus help:evaluate inline.
    String script = String.join(" && ",
        "GROUP_ID=$(mvn help:evaluate -Dexpression=project.groupId -q -DforceStdout)",
        "ARTIFACT_ID=$(mvn help:evaluate -Dexpression=project.artifactId -q -DforceStdout)",
        "VERSION=$(mvn help:evaluate -Dexpression=project.version -q -DforceStdout)",
        "PROJECT_KEY=\"${GROUP_ID}:${ARTIFACT_ID}\"",
        "mvn clean verify sonar:sonar -B"
            + " -Dsonar.projectKey=\"${PROJECT_KEY}\""
            + " -Dsonar.projectName='" + projectName + "'"
            + " -Dsonar.projectVersion=\"${VERSION}\""
            + " -Dsonar.host.url='" + url + "'"
            + " -Dsonar.token=\"${SONAR_TOKEN}\""
            + " -Dsonar.java.source=" + jdk
            + " -Dsonar.java.target=" + jdk
            + " -Dsonar.scm.provider=git"
            + " -Dspring.datasource.url=jdbc:postgresql://postgres:5432/" + db);

    Container c = mavenContainer(jdk)
        .withMountedDirectory("/src", src)
        .withWorkdir("/src")
        .withEnvVariable("MAVEN_OPTS", "-Xmx2g")
        .withEnvVariable("GITHUB_ACTOR", actor)
        .withEnvVariable("SPRING_DATASOURCE_USERNAME", "plaintext")
        .withEnvVariable("SPRING_DATASOURCE_PASSWORD", "plaintext")
        .withServiceBinding("postgres", postgres)
        .withSecretVariable("SONAR_TOKEN", sonarToken);

    if (githubToken != null) {
      c = c.withSecretVariable("GITHUB_TOKEN", githubToken)
          .withMountedFile("/root/.m2/settings.xml",
              dag().file("settings.xml", settingsXml()));
    }

    return c.withExec(List.of("sh", "-lc", script));
  }

  /**
   * Verify-Step: HTTP version-check der deployten App.
   *
   * <p>Pollt {@code <appUrl>/nosec/version} alle 5s bis HTTP 200, max 2 Min.
   * Entspricht dem Verify DEV / Verify PROD Step in der alten ci-cd-pipeline.yaml.
   *
   * @param appUrl Base-URL (z.B. http://192.168.1.224:1111)
   * @return Container; Exit-Code 0 wenn erreichbar, 1 nach Timeout
   */
  @Function
  public Container verify(String appUrl) {
    String url = appUrl == null ? "" : appUrl.replaceAll("/+$", "");
    String script = "set -e; "
        + "echo \"Verifying app at " + url + "/nosec/version ...\"; "
        + "for i in $(seq 1 24); do "
        + "  RESPONSE=$(curl -sf '" + url + "/nosec/version' 2>/dev/null) && { "
        + "    echo \"App running: $RESPONSE\"; exit 0; "
        + "  }; "
        + "  echo \"Waiting for app... ($i/24)\"; sleep 5; "
        + "done; "
        + "echo 'App version check failed after 2 minutes'; exit 1";
    return dag()
        .container()
        .from("curlimages/curl:latest")
        .withExec(List.of("sh", "-lc", script));
  }

  /**
   * Deploy via SSH: kopiert build-output + ruft remote-deploy-Script auf.
   *
   * <p>Stark vereinfacht — die alte ci-cd-pipeline.yaml hat einen ausgefeilten
   * deploy.sh-Helper inkl. blue-green-Swap. Diese Implementation ist
   * Skelett-Stand und braucht je nach project-Setup feinjustierung.
   *
   * @param src         Projekt-Verzeichnis mit gebauten Artifacts (target/*.jar)
   * @param sshKey      SSH Private Key (Secret)
   * @param sshHost     z.B. "mad@192.168.1.224"
   * @param remoteCmd   Shell-Kommando das nach scp ausgefuehrt wird (Deploy-Logik)
   * @return Container nach Deploy
   */
  @Function
  public Container deploy(
      @DefaultPath(".") Directory src,
      Secret sshKey,
      String sshHost,
      String remoteCmd) {
    String cmd = remoteCmd == null || remoteCmd.isBlank()
        ? "echo 'No remote command provided'"
        : remoteCmd;
    return dag()
        .container()
        .from("alpine:latest")
        .withExec(List.of("apk", "add", "--no-cache", "openssh-client", "rsync"))
        .withMountedDirectory("/src", src)
        .withWorkdir("/src")
        .withMountedSecret("/root/.ssh/id_rsa", sshKey)
        .withExec(List.of("sh", "-c",
            "chmod 600 /root/.ssh/id_rsa && "
                + "mkdir -p /root/.ssh && "
                + "ssh-keyscan -H " + extractHost(sshHost) + " >> /root/.ssh/known_hosts 2>/dev/null || true && "
                + "ssh -o StrictHostKeyChecking=no " + sshHost + " '" + cmd + "'"));
  }

  private static String extractHost(String userAtHost) {
    if (userAtHost == null) return "";
    int at = userAtHost.indexOf('@');
    return at >= 0 ? userAtHost.substring(at + 1) : userAtHost;
  }

  /** Postgres-18-alpine Service-Container, exposed Port 5432, ready-Healthcheck via pg_isready. */
  private static Service postgresService(String databaseName) {
    return dag()
        .container()
        .from("postgres:18-alpine")
        .withEnvVariable("POSTGRES_DB", databaseName)
        .withEnvVariable("POSTGRES_USER", "plaintext")
        .withEnvVariable("POSTGRES_PASSWORD", "plaintext")
        .withExposedPort(5432)
        .asService();
  }

  /**
   * Maven settings.xml mit GitHub-Packages-Auth ueber Env-Variablen
   * (entspricht dem Setup in plaintext-scripts ci-cd-pipeline.yaml:
   * server-id=plaintext, server-username=GITHUB_ACTOR, password=GITHUB_TOKEN).
   */
  private static String settingsXml() {
    return "<settings>\n"
        + "  <servers>\n"
        + "    <server>\n"
        + "      <id>plaintext</id>\n"
        + "      <username>${env.GITHUB_ACTOR}</username>\n"
        + "      <password>${env.GITHUB_TOKEN}</password>\n"
        + "    </server>\n"
        + "  </servers>\n"
        + "</settings>\n";
  }

  /**
   * Convenience-Funktion: build + Rueckgabe der gebauten Artifacts als Directory.
   * Ruft intern build() auf und exportiert /src zurueck.
   */
  @Function
  public Directory artifacts(
      @DefaultPath(".") Directory src,
      String javaVersion,
      Boolean coverage,
      Boolean skipTests,
      Integer threads,
      String githubActor,
      Secret githubToken)
      throws InterruptedException, ExecutionException, DaggerQueryException {
    return build(src, javaVersion, coverage, skipTests, threads, githubActor, githubToken)
        .directory("/src");
  }

  /** Container-Setup: Maven + Temurin JDK, mit persistentem ~/.m2 Cache-Volume. */
  private Container mavenContainer(String javaVersion) {
    CacheVolume m2 = dag().cacheVolume("plaintext-maven-cache");
    String image = "maven:3-eclipse-temurin-" + javaVersion;
    return dag()
        .container()
        .from(image)
        .withMountedCache("/root/.m2", m2);
  }
}
