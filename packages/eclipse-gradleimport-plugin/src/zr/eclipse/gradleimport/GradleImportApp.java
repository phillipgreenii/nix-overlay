package zr.eclipse.gradleimport;
import java.io.File;
import org.eclipse.buildship.core.*;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.NullProgressMonitor;
import org.eclipse.equinox.app.IApplication;
import org.eclipse.equinox.app.IApplicationContext;
public class GradleImportApp implements IApplication {
  public Object start(IApplicationContext ctx) throws Exception {
    String[] a = (String[]) ctx.getArguments().get(IApplicationContext.APPLICATION_ARGS);
    if (a == null || a.length == 0) { System.err.println("usage: <projectRootDir>"); return Integer.valueOf(2); }
    File root = new File(a[0]).getCanonicalFile();
    BuildConfiguration cfg = BuildConfiguration.forRootProjectDirectory(root).overrideWorkspaceConfiguration(false).build();
    GradleBuild build = GradleCore.getWorkspace().createBuild(cfg);
    IStatus s = build.synchronize(new NullProgressMonitor()).getStatus();
    // Do NOT join the job manager here. Joining the all-jobs family
    // (IJobManager.join(null, ...)) blocks forever on perpetual Eclipse jobs
    // (the JDT indexer, auto-build) that never terminate, so the headless app
    // could never exit (verified: hangs at this line after a successful import).
    // synchronize() has already registered and persisted the projects, so
    // returning immediately is the proven-correct behavior. Benign post-sync log
    // noise ("Resource '/x' does not exist"; "still running at shutdown") is
    // cosmetic; the `ec` wrapper captures/suppresses it rather than blocking here.
    System.out.println("[gradle-import] status: " + (s.isOK() ? "OK" : s.getMessage()));
    return s.isOK() ? IApplication.EXIT_OK : Integer.valueOf(1);
  }
  public void stop() {}
}
