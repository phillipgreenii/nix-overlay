# eclipse-gradleimport-plugin — headless Buildship Gradle import

Headless Eclipse application that registers a whole Gradle composite into a workspace without the
GUI import wizard. SOURCE OF TRUTH is this directory (`GradleImportApp.java` +
`META-INF/MANIFEST.MF` + `plugin.xml`), compiled by `default.nix` (javac against the Eclipse
derivation's plugins jars, jdk17) and composed into Eclipse.app by
`packages/eclipse-with-gradleimport`. Productionized in epic `pg2-e1z4v`; notes extracted
2026-08-17 from a bd memory.

- Bundle: `zr.eclipse.gradleimport`; application id: `zr.eclipse.gradleimport.headless`.
- Invocation:
  `eclipse -noSplash -data <ws> -application zr.eclipse.gradleimport.headless <projectRoot>` —
  registers the whole Gradle composite (verified: 133 projects for `finance/api_parent`), prints
  `[gradle-import] status: OK`, exit 0.

## Two hard-won production learnings — do NOT regress

1. **NEVER add `IJobManager.join(null, monitor)` "hardening".** It HANGS FOREVER — joining the
   all-jobs family blocks on perpetual Eclipse jobs (JDT indexer, auto-build) that never
   terminate; the import succeeds but the process never exits (thread-dump-confirmed). The
   correct behavior is to simply return after `synchronize()` (the original prototype behavior);
   projects persist without any join. `Require-Bundle` needs only `org.eclipse.core.runtime`,
   `org.eclipse.buildship.core`, `org.eclipse.equinox.app` (`core.jobs` NOT needed once the join
   is gone).
2. **Install the plugin via `plugins/` + simpleconfigurator `bundles.info`, NOT `dropins/`.** On
   a cold read-only nix-store config the dropins reconciler is async and races the `-application`
   lookup → "Application ... could not be found in the registry". `bundles.info` loads the bundle
   deterministically at start level 4 and needs no writable config. (This SUPERSEDES an earlier
   "copy the jar into dropins works" note, which only held for a warm GUI-first prototype.)

## Launcher/wrapper notes

- `bin/eclipse` must be an exec WRAPPER, not a symlink — the Cocoa launcher resolves
  `eclipse.ini`'s relative `../Eclipse` against the invocation path.
- The composed wrapper bakes `--launcher.suppressErrors`: the EPP UI product pops a modal NSAlert
  on non-zero exit that hangs headless runs.
- Benign ~100-line Eclipse/OSGi log noise on the success path is captured by the `ec` wrapper
  (in `phillipg-nix-ziprecruiter`) to `<ws>/.ec-import.log`, not shown.
