{
  lib,
  stdenv,
  jdk17,
  unzip,
  eclipse-java,
}:
stdenv.mkDerivation {
  pname = "eclipse-gradleimport-plugin";
  version = "0.1.0";

  # Source lives in-repo (this package dir); no nvfetcher-pinned `sources` entry.
  src = ./.;

  # JavaSE-17 per the bundle manifest (Bundle-RequiredExecutionEnvironment).
  # unzip is used by the installCheck to read the packaged MANIFEST.MF.
  nativeBuildInputs = [
    jdk17
    unzip
  ];

  buildPhase = ''
    runHook preBuild
    # Compile classpath = every jar shipped in the Eclipse install's plugins dir.
    # Some bundles are exploded directories rather than jars; the jars on the
    # classpath cover the APIs this bundle imports (buildship.core, core.runtime,
    # core.jobs, equinox.app). Jar names carry upstream version qualifiers, so
    # glob them rather than hardcoding versions.
    ECLIPSE_PLUGINS="${eclipse-java}/Applications/Eclipse.app/Contents/Eclipse/plugins"
    CP=$(find "$ECLIPSE_PLUGINS" -maxdepth 1 -name '*.jar' | tr '\n' ':')

    mkdir -p classes
    javac -cp "$CP" -d classes src/zr/eclipse/gradleimport/GradleImportApp.java

    # Stage the OSGi metadata alongside the compiled classes and assemble the
    # bundle jar. `jar cfm` uses META-INF/MANIFEST.MF as the manifest and adds
    # plugin.xml plus the compiled `zr` package tree.
    mkdir -p classes/META-INF
    cp META-INF/MANIFEST.MF classes/META-INF/MANIFEST.MF
    cp plugin.xml classes/plugin.xml
    ( cd classes && jar cfm bundle.jar META-INF/MANIFEST.MF plugin.xml zr )
    runHook postBuild
  '';

  # No unit test: exercising this bundle requires a full Eclipse runtime, which
  # is covered end-to-end by the eclipse-with-gradleimport launch smoke test.
  doCheck = false;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/eclipse-dropins
    # OSGi dropins convention: <bundle-symbolic-name>_<version>.jar
    cp classes/bundle.jar $out/share/eclipse-dropins/zr.eclipse.gradleimport_0.1.0.jar
    runHook postInstall
  '';

  dontFixup = true;

  # Shift-left: assert the produced bundle jar is well-formed. `jar tf` lists the
  # entries; the packaged manifest is unfolded (jar rewrites headers with CRLF
  # and 72-column continuation wraps) before grepping for the required headers.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    jar="$out/share/eclipse-dropins/zr.eclipse.gradleimport_0.1.0.jar"
    test -f "$jar"

    entries=$(jar tf "$jar")
    echo "$entries" | grep -qx 'zr/eclipse/gradleimport/GradleImportApp.class'
    echo "$entries" | grep -qx 'plugin.xml'
    echo "$entries" | grep -qx 'META-INF/MANIFEST.MF'

    # Unfold the packaged manifest: strip CR, then join continuation lines
    # (newline followed by a leading space) so wrapped headers match on one line.
    mf=$(unzip -p "$jar" META-INF/MANIFEST.MF | tr -d '\r' | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n //g')
    echo "$mf" | grep -q '^Bundle-SymbolicName: zr.eclipse.gradleimport'
    echo "$mf" | grep -E '^Require-Bundle:' | grep -q 'org.eclipse.buildship.core'
    runHook postInstallCheck
  '';

  meta = {
    description = "OSGi bundle providing the headless zr.eclipse.gradleimport.headless Buildship Gradle-import application for Eclipse";
    homepage = "https://www.eclipse.org";
    license = lib.licenses.epl20;
    # Compiled against the aarch64-darwin Eclipse install's plugin jars.
    platforms = [ "aarch64-darwin" ];
  };
}
