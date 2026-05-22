package io.dagger.modules.plaintextbuild;

import static io.dagger.client.Dagger.dag;

import io.dagger.client.CacheVolume;
import io.dagger.client.Container;
import io.dagger.client.Directory;
import io.dagger.client.Secret;
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
