# tc-32sf5: select the buildGoNNNModule matching a package's own go.mod
# minimum, instead of hand-editing `buildGoModule` -> `buildGoNNNModule`
# (and re-hashing vendorHash) every time nixpkgs' bundled default `go` falls
# behind a package's requirement -- as happened with pint v0.88.0 (go.mod
# `go 1.27.0`) against this branch's default go 1.26.7, under
# GOTOOLCHAIN=local which blocks the sandboxed build from self-fetching a
# newer toolchain.
#
# nixpkgs ships one buildGoNNNModule per go release still carried on the
# pinned branch (e.g. buildGo123Module/buildGo125Module/buildGo126Module/
# buildGo127Module on nixpkgs-26.05) -- at least two are available side by
# side by construction, so different packages here may legitimately pin
# different minimums at the same time. A package falls off an older pin by
# bumping its own `goVersion` (or dropping the argument entirely once
# nixpkgs' bare default catches back up) -- this file carries no
# per-version list to prune as that happens.
#
# Scope: this is for the plain `buildGoModule` + `vendorHash` family used by
# nix-overlay's third-party Go repackages (pint, gh-stack, glowm, gomu, ...).
# It is unrelated to phillipgreenii-nix-repo-base's `mkGoApp`/`mkGoBinary`
# (gomod2nix-engine, first-party Go apps) -- see that repo's CLAUDE.md,
# "Go packages (mkGoApp / mkGoBinary)": raw buildGoModule packages that don't
# go through those helpers keep their own vendorHash, which this file does
# not touch.
{ lib }:
# pkgs: the (overlay-extended) package set to resolve the builder from.
# goVersion: the package's go.mod `go` directive as "X.Y" (e.g. "1.27"), or
#   `null` to keep using nixpkgs' current default `buildGoModule` -- correct
#   for a package whose go.mod requirement the pinned default `go` already
#   satisfies.
pkgs: goVersion:
if goVersion == null then
  pkgs.buildGoModule
else
  let
    attrName = "buildGo${lib.replaceStrings [ "." ] [ "" ] goVersion}Module";
  in
  pkgs.${attrName} or (throw ''
    versioned-go-module: requested go ${goVersion} (nixpkgs attribute
    `${attrName}`) but this nixpkgs pin does not carry it. Either nixpkgs
    dropped that toolchain -- bump the package's declared `goVersion` to one
    nixpkgs still ships (`nix eval .#legacyPackages.<system> --apply
    'pkgs: builtins.filter (n: builtins.match "buildGo[0-9]+Module" n !=
    null) (builtins.attrNames pkgs)'` lists what this pin carries) -- or the
    version string is malformed (expected e.g. "1.27", not "v1.27.0" or
    "1.27.0").
  '')
