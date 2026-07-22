{
  lib,
  stdenvNoCC,
  eclipse-java,
  eclipse-gradleimport-plugin,
  sources,
}:
stdenvNoCC.mkDerivation {
  pname = "eclipse-with-gradleimport";
  inherit (eclipse-java) version;

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications $out/bin

    # Copy (not symlink) the Eclipse tree so it is writable and the plugin can be
    # installed into it. A symlinked tree could not be modified, and Equinox also
    # ignores symlinked bundles.
    cp -R ${eclipse-java}/Applications/*.app $out/Applications/
    chmod -R u+w $out/Applications

    eclipseDir="$out/Applications/Eclipse.app/Contents/Eclipse"

    # Install the headless-import bundle as a FIRST-CLASS plugin registered in
    # simpleconfigurator's bundles.info, rather than dropping it in dropins/.
    #
    # DEVIATION from the original spec (dropins), required for correctness and
    # verified by debugging the launch: the dropins reconciler is asynchronous
    # and racy on a cold configuration area. Because the launch overrides the
    # application (`-application zr.eclipse.gradleimport.headless`), the app is
    # frequently looked up before the reconciler has installed our bundle,
    # producing `RuntimeException: Application "..." could not be found in the
    # registry`. On macOS the Cocoa launcher renders that exception as a modal
    # NSAlert (displayMessage -> [NSAlert runModal]) that never returns in a
    # headless/CLI context, so the process HANGS FOREVER. bundles.info is read
    # verbatim at every startup, requires no writable configuration area (the
    # store install is read-only), and makes the application deterministically
    # available at start level 4 — no reconciliation, no race, no dialog.
    cp ${eclipse-gradleimport-plugin}/share/eclipse-dropins/zr.eclipse.gradleimport_0.1.0.jar \
      "$eclipseDir/plugins/zr.eclipse.gradleimport_0.1.0.jar"
    binfo="$eclipseDir/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
    echo 'zr.eclipse.gradleimport,0.1.0,plugins/zr.eclipse.gradleimport_0.1.0.jar,4,true' >> "$binfo"

    # --- Project Lombok javaagent ---
    # Eclipse/JDT recognizes Lombok's generated members only when lombok.jar is
    # loaded as a JVM `-javaagent`: the agent patches Eclipse's ECJ compiler at
    # class-load time. The app is a read-only nix store path, so the usual
    # `java -jar lombok.jar` GUI installer (which edits eclipse.ini in place)
    # cannot be run against it — bake the agent in at build time instead.
    #
    # Copy the jar as a REAL, writable file (chmod +w — the fetchurl store source
    # is read-only) alongside the launcher/config, NOT a symlink.
    cp ${sources.lombok.src} "$eclipseDir/lombok.jar"
    chmod +w "$eclipseDir/lombok.jar"

    # eclipse.ini is one-argument-per-line, and everything after the `-vmargs`
    # line is passed to the JVM. Appending a single `-javaagent` line at
    # END-OF-FILE therefore lands in the JVM-args section without disturbing any
    # existing content. Point it at the ABSOLUTE store path of the jar we just
    # copied (`$out/.../Contents/Eclipse/lombok.jar`, i.e. `$eclipseDir/...`):
    # the JVM resolves `-javaagent` against the launcher's cwd, so a relative
    # path would be unsafe. `$out` is the final output store path at build time,
    # so the correct absolute path is baked in. Do NOT add any
    # `jdk.compiler --add-opens` flags — those target javac, not Eclipse's ECJ.
    echo "-javaagent:$eclipseDir/lombok.jar" >> "$eclipseDir/eclipse.ini"

    # Exec wrapper, not a symlink — see the eclipse-java package for the path
    # rationale. It also injects `--launcher.suppressErrors`, which is REQUIRED
    # for headless use: the EPP product is a UI product, so the macOS Cocoa
    # launcher initializes AppKit; when the application returns a NON-ZERO exit
    # code (this bundle returns 2 for the usage path and 1 on import failure)
    # the launcher pops a modal "JVM terminated. Exit code=N" NSAlert that never
    # returns without a human to dismiss it, hanging the process forever.
    # `--launcher.suppressErrors` turns those dialogs into stderr diagnostics and
    # lets the launcher exit with the application's code. (Successful imports
    # return 0 and never triggered the dialog; the error/usage paths did.)
    launcher="$out/Applications/Eclipse.app/Contents/MacOS/eclipse"
    {
      echo '#!/bin/sh'
      echo "exec \"$launcher\" --launcher.suppressErrors \"\$@\""
    } > $out/bin/eclipse
    chmod +x $out/bin/eclipse
    runHook postInstall
  '';

  # Shift-left: assert the plugin bundle is installed as a REAL copied file (not
  # a symlink — Equinox ignores symlinked bundles) in plugins/ AND registered in
  # bundles.info so it loads deterministically, plus the launcher wrapper. All
  # file inspection; no app launch (sandbox-safe).
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    eclipseDir="$out/Applications/Eclipse.app/Contents/Eclipse"
    jar="$eclipseDir/plugins/zr.eclipse.gradleimport_0.1.0.jar"
    test -f "$jar"
    test ! -L "$jar"
    grep -q '^zr.eclipse.gradleimport,0.1.0,plugins/zr.eclipse.gradleimport_0.1.0.jar,' \
      "$eclipseDir/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info"
    test -x "$out/Applications/Eclipse.app/Contents/MacOS/eclipse"
    # bin/eclipse is an executable wrapper that execs the real launcher with
    # --launcher.suppressErrors (required so the headless non-zero-exit path does
    # not hang on a modal "JVM terminated" dialog).
    test -x "$out/bin/eclipse"
    grep -q 'Contents/MacOS/eclipse' "$out/bin/eclipse"
    grep -q -- '--launcher.suppressErrors' "$out/bin/eclipse"
    # Lombok javaagent baked in: the jar must be a REAL copied file (not a store
    # symlink — the -javaagent must resolve to real bytes) and eclipse.ini must
    # load it via a -javaagent line so JDT's ECJ sees the agent.
    lombokJar="$eclipseDir/lombok.jar"
    test -f "$lombokJar"
    test ! -L "$lombokJar"
    grep -q -- '-javaagent:.*lombok.jar' "$eclipseDir/eclipse.ini"
    runHook postInstallCheck
  '';

  meta = {
    description = "Eclipse IDE for Java Developers with the zr.eclipse.gradleimport headless Gradle-import bundle installed";
    homepage = "https://www.eclipse.org";
    # Composes the prebuilt Eclipse .app (native Mach-O bundle).
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    license = lib.licenses.epl20;
    platforms = [ "aarch64-darwin" ];
  };
}
