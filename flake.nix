{
  description = "Third-party Nix packages absent from or outdated in nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    phillipgreenii-nix-base = {
      url = "github:phillipgreenii/nix-repo-base";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # flake-parts: framework for the consumed nix-base flakeModules. Deduped onto
    # nix-base's pin so it is a single shared node (inherits nix-base's
    # nixpkgs-lib follow; no extra wiring needed). Fleet convention — every other
    # consumer (agent-support, support-apps, ziprecruiter) follows the same pin.
    flake-parts.follows = "phillipgreenii-nix-base/flake-parts";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Mirror flake-utils.lib.defaultSystems verbatim — do NOT drop x86_64-darwin.
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      imports = [
        # pre-commit transitively imports treefmt
        inputs.phillipgreenii-nix-base.flakeModules.pre-commit
        inputs.phillipgreenii-nix-base.flakeModules.devshell
        inputs.phillipgreenii-nix-base.flakeModules.checks
      ];

      perSystem =
        {
          pkgs,
          config,
          ...
        }:
        let
          # Single overlay-applied instantiation shared by `packages` and
          # `legacyPackages` so the two never derive the same content through
          # two different pkgs scopes (plain pkgs vs pkgs.extend) and drift
          # apart (pg2-24530).
          extended = pkgs.extend self.overlays.default;
        in
        {
          # formatter, devShells.default, packages.install-pre-commit-hooks,
          # checks.{formatting, linting, pre-commit, consumer-input-alignment}
          # — all auto-contributed.

          # devshell.extraInputs — see nix-repo-base/flake-modules/devshell.nix:7.
          # nvfetcher's generated _sources/ tree is excluded from lint+format by the
          # producer default (tc-uergy), so no per-repo overrides are needed here.
          phillipgreenii.devshell.extraInputs = with pkgs; [
            jq
            curl
            gnused
            nvfetcher
            # Tools the non-no-op verify-provenance.sh methods need. They are
            # dormant today (every upstream uses a skip method), but the moment
            # a METHODS entry flips to attestation/checksums/sigstore the step
            # shells out to these — and cosign/gh are not preinstalled on the
            # runners. Ship them in the shell so the hook actually runs (pg2-qnzrt).
            gh # verify_attestation: gh attestation verify
            cosign # verify_sigstore: cosign verify-blob
            xxd # verify_checksums: xxd -r -p
          ];

          # Build every package as a check. Use config.packages (same-perSystem
          # scope) rather than self.packages.${system} which forces an eval
          # cycle through flake-parts' mkPerSystemFile.
          checks =
            config.packages
            // {
              # Run the verify-provenance.sh bats suite as a CI check so a
              # regression in the provenance helper — including the SRI-pin
              # TOCTOU fix (pg2-oqrus) and the jq-vs-awk cross-package bleed
              # fix (pg2-xb4zc) — fails the build instead of going unnoticed
              # (pg2-q5mjn). The suite sources ../verify-provenance.sh relative
              # to its own dir, so stage both into that layout. Two tests call
              # `nix hash file`, which is a pure local hash (no store writes, no
              # recursive-nix) and runs fine in the sandbox; NIX_CONFIG enables
              # the nix-command feature on runners that don't default it on.
              verify-provenance-tests =
                pkgs.runCommand "verify-provenance-tests"
                  {
                    nativeBuildInputs = [
                      pkgs.bats
                      pkgs.jq
                      pkgs.coreutils
                      pkgs.nix
                    ];
                  }
                  ''
                    export HOME="$TMPDIR/home"
                    mkdir -p "$HOME"
                    export NIX_CONFIG="experimental-features = nix-command"
                    mkdir -p suite/tests
                    cp ${./verify-provenance.sh} suite/verify-provenance.sh
                    cp ${./tests/verify-provenance.bats} suite/tests/verify-provenance.bats
                    bats suite/tests
                    touch "$out"
                  '';
            }
            // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
              # Eval-only smoke check for the opt-in firefox-binary-wrapper
              # overlay (bead pg2-pimam). Forcing firefox.drvPath instantiates
              # the overlay's overrideAttrs — including its sentinel assertion
              # that upstream's buildCommand still contains the `makeWrapper`
              # string we rewrite — so a nixpkgs bump that voids the assertion
              # fails CI here, not silently in a consumer's darwin-rebuild.
              #
              # The force happens via `seq` at EVAL time and firefox is kept out
              # of the produced derivation's build inputs (no drvPath in the
              # command string): `nix flake check` realizes only the trivial
              # marker, never the 3.7 GiB firefox closure.
              #
              # This does NOT cover the /usr/bin/codesign impurity that the same
              # buildCommand shells out to (it breaks under sandbox=true); the
              # sandbox-safe rework (rcodesign/sigtool) is deferred to the
              # overlay-rework initiative, per the note in the overlay itself.
              firefox-binary-wrapper-eval =
                let
                  pkgsFx = pkgs.extend self.overlays.firefox-binary-wrapper;
                  # WHNF-force the drvPath string (runs the assertion + the
                  # overrideAttrs) then discard it, so nothing firefox-shaped
                  # reaches the marker derivation's context.
                  assertionHeld = builtins.seq pkgsFx.firefox.drvPath null;
                in
                builtins.seq assertionHeld (
                  pkgs.runCommand "firefox-binary-wrapper-eval" { } ''
                    echo "firefox-binary-wrapper overlay evaluated (sentinel assertion held)" >"$out"
                  ''
                );
            };

          packages = {
            inherit (extended.phillipgreenii)
              bat-gherkin-syntax
              pint
              ;
            inherit (extended.tmuxPlugins)
              tmux-open-nvim
              tmux-mouse-swipe
              tmux-nerd-font-window-name
              ;
            yaziPlugins-icons-brew = extended.yaziPlugins.icons-brew;
            yaziPlugins-bunny = extended.yaziPlugins.bunny;

            # fix-lint + install-pre-commit-hooks REMOVED — pre-commit module
            # auto-contributes both (bead pg2-7vhvn). This flake's cwd-correct
            # fix-lint variant is the one now shipped from base.
          }
          // pkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") {
            inherit (extended.phillipgreenii) cmux;
          };

          legacyPackages = {
            yaziPlugins = { inherit (extended.yaziPlugins) icons-brew bunny; };
          };
        };

      flake = {
        # Shape-B wrapper: imports the producer's HM module and sets options
        # with this flake's self + name. Downstream consumers see the configured
        # module shape (no further options to set).
        homeModules.install-metadata = { ... }: {
          imports = [ inputs.phillipgreenii-nix-base.homeModules.install-metadata ];
          phillipgreenii.install-metadata = {
            flakeSelf = self;
            name = "phillipgreenii-nix-overlay";
          };
        };

        overlays.firefox-binary-wrapper = import ./overlays/firefox-binary-wrapper.nix;

        overlays.default =
          final: prev:
          let
            sources = final.callPackage ./_sources/generated.nix { };
          in
          {
            phillipgreenii = {
              bat-gherkin-syntax = final.callPackage ./packages/bat-gherkin-syntax { inherit sources; };
              pint = final.callPackage ./packages/pint { inherit sources; };
            }
            // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
              cmux = final.callPackage ./packages/cmux { inherit sources; };
            };
            tmuxPlugins = prev.tmuxPlugins // {
              tmux-open-nvim = final.callPackage ./packages/tmux-open-nvim { inherit sources; };
              tmux-mouse-swipe = final.callPackage ./packages/tmux-mouse-swipe { inherit sources; };
              tmux-nerd-font-window-name = final.callPackage ./packages/tmux-nerd-font-window-name {
                inherit sources;
              };
            };
            yaziPlugins =
              prev.yaziPlugins
              // (
                let
                  # Pass prev.yaziPlugins explicitly so mkYaziPlugin resolves to
                  # nixpkgs' builder without recursing through this override.
                  ours = final.callPackage ./packages/yaziPlugins {
                    inherit sources;
                    inherit (prev) yaziPlugins;
                  };
                in
                {
                  inherit (ours) icons-brew bunny;
                }
              );

            # TEMPORARY back-compat bridge for the A5 namespacing migration
            # (commit 1b17129 moved overlay packages under `phillipgreenii.*`).
            # Unmigrated consumers (nix-personal, agent-support) still reference
            # the old top-level names, so re-expose aliases to keep them building
            # until the consumer-side ADR-0047 migration lands. Remove then.
            # NOTE: c9watch was genuinely dropped (not just moved) and so cannot
            # be aliased here — it is disabled at the consumer instead.
            inherit (final.phillipgreenii) bat-gherkin-syntax;
          }
          // prev.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
            # cmux only exists under phillipgreenii.* on aarch64-darwin (see above).
            inherit (final.phillipgreenii) cmux;
          };
      };
    };
}
