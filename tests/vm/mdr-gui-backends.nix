# NixOS VM integration test (V-4): the mdr egui and webview backends each open a
# window on Linux. Guards the runpath/LD_LIBRARY_PATH wiring in
# packages/mdr-rs/default.nix: /run/opengl-driver/lib (supplied here by
# hardware.graphics, mesa llvmpipe) in the runpath and libxkbcommon first on
# LD_LIBRARY_PATH. Exposed only as legacyPackages.<system>.integration-checks,
# never as a `checks` attribute.
{ pkgs, mdr }:
pkgs.testers.runNixOSTest {
  name = "mdr-gui-backends";

  nodes.machine =
    { pkgs, ... }:
    {
      hardware.graphics.enable = true;
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        mdr
        pkgs.xdotool
        pkgs.xorg.xwininfo
        pkgs.xorg.xorgserver # Xvfb
      ];
      systemd.services.xvfb = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.xorg.xorgserver}/bin/Xvfb :0 -screen 0 1024x768x24 +extension GLX";
      };
    };

  testScript = ''
    machine.wait_for_unit("xvfb.service")
    machine.wait_for_file("/tmp/.X11-unix/X0")
    machine.succeed("echo '# mdr vm test' > /tmp/test.md; echo 'hello **world**' >> /tmp/test.md")

    # CLI names: gui = egui native window, web = system webview (WebKitGTK).
    for backend in ["gui", "web"]:
        logfile = f"/tmp/mdr-{backend}.logfile"
        machine.succeed(
            f"DISPLAY=:0 sh -c 'mdr --backend {backend} /tmp/test.md > {logfile} 2>&1 & echo $! > /tmp/mdr-{backend}.pid'"
        )
        # A visible window owned by the mdr process proves the backend started.
        try:
            machine.wait_until_succeeds(
                f"DISPLAY=:0 xdotool search --onlyvisible --pid $(cat /tmp/mdr-{backend}.pid) | grep .",
                timeout=120,
            )
        except Exception:
            print(machine.execute(f"cat {logfile}; ps aux; DISPLAY=:0 xwininfo -root -tree")[1])
            raise
        print(machine.succeed(f"cat {logfile}"))
        machine.succeed(f"kill -0 $(cat /tmp/mdr-{backend}.pid)")
        machine.fail(
            f"grep -Ei 'dlopen|cannot open shared object|error while loading shared libraries|libxkbcommon.*not found|libEGL.*(cannot|not found|failed to load)|libGL.*not found|failed to load' {logfile}"
        )
        machine.succeed(f"kill $(cat /tmp/mdr-{backend}.pid)")
        machine.wait_until_fails(f"kill -0 $(cat /tmp/mdr-{backend}.pid)")
  '';
}
