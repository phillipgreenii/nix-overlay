#!/usr/bin/env bats
# bats file_tags=type:integration
# Runs the REAL refresh-dependent-hashes.sh step -- real `nix build`, real
# fixed-output `got:` mismatch output -- against a throwaway fixture flake
# (bead pg2-g39wh). Nothing is mocked except the source updater (a stand-in for
# nvfetcher that just rewrites versions in the fixture's generated files).
#
# The fixture's "dependency fetch" is a fixed-output derivation whose content is
# the source version string, so a bump changes the correct hash exactly like a
# changed pnpm-lock.yaml does. A version containing AGE makes the FOD builder
# fail with pnpm's own ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION line; BROKEN makes
# the package build itself fail (the cmux 0.65.1 class).
#
# Offline, but it needs a nix daemon that can run a local builder, so it is
# skipped inside the nix build sandbox (the checks.* tier cannot nest builds).
#
# type:integration (V-4: a real nix build is not a unit test; operator ruling
# 2026-10-28, bead pg2-om5ith), so the unit-tier run-unit-tests commit hook and
# pre-land never select it. Opt in with `nix run .#refresh-dependent-hashes-nix-tests`
# (docs/update-locks-dependent-hashes.md, "Real-nix integration suite").

setup() {
  if [ -n "${IN_NIX_BUILD:-}" ] || [ -n "${NIX_BUILD_TOP:-}" ]; then
    skip "inside the nix build sandbox: no nested nix builds"
  fi
  command -v nix >/dev/null 2>&1 || skip "nix not on PATH"

  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/refresh-dependent-hashes.sh"
  FX="$(cd "$(mktemp -d)" && pwd -P)"
  NONCE="rdhfx-$$-${RANDOM}${RANDOM}"
  SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
  BUILDER="$(readlink -f "$(command -v bash)")"

  mkdir -p "${FX}/_sources"
  write_flake
  # key=version
  write_state fresh=v1 aged=a1 plain=p1 stable=s1 offsys=o1 pinned=v1.1.0
  local k
  for k in fresh aged stable; do
    mkdir -p "${FX}/packages/${k}"
    printf '{\n  hash = "%s";\n}\n' "$(hash_of "$(version_of "$k")")" >"${FX}/packages/${k}/default.nix"
  done

  cat >"${FX}/registry.bash" <<'EOF'
BUILD_ATTRS=(
  [fresh]="fresh"
  [aged]="aged"
  [plain]="plain"
  [stable]="stable"
  [offsys]="not-a-package-here"
  [brandnew]="brandnew"
  [pinned]="pinned"
)
HASH_DEPS=(
  [fresh]="packages/fresh/default.nix:hash:fresh"
  [aged]="packages/aged/default.nix:hash:aged"
  [stable]="packages/stable/default.nix:hash:stable"
)
MANUAL_DEPS=()
PIN_GUARDS=([pinned]="fxbase:pin.nix")
EOF

  # A stand-in for the locked nix-repo-base: a real directory holding a pin file,
  # reached through a real lock-file node, read by the real rdh_read_pin
  # (builtins.fetchTree of the node's `locked` attrs). Kept out of flake.lock so
  # the fixture flake itself stays input-free.
  mkdir -p "${FX}/fxbase"
  write_pin 1.1.0
  jq -n --arg p "${FX}/fxbase" \
    '{nodes: {root: {inputs: {fxbase: "fxbase"}}, fxbase: {locked: {type: "path", path: $p}}}, root: "root", version: 7}' \
    >"${FX}/fx.lock"
  export RDH_LOCK_FILE="${FX}/fx.lock"

  # Stand-in for nvfetcher: rewrite versions in both generated files.
  # usage: bump.sh key=version...   (a key not yet present is added)
  cat >"${FX}/bump.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for kv in "$@"; do
  k="${kv%%=*}"
  v="${kv#*=}"
  out=$(jq --indent 4 -S --arg k "$k" --arg v "$v" '.[$k] = ((.[$k] // {pname: $k}) | .version = $v)' _sources/generated.json)
  printf '%s' "$out" >_sources/generated.json
  if grep -qx "  $k = {" _sources/generated.nix; then
    sed -E "/^  $k = \{/,/^  \};/ s/version = \"[^\"]*\"/version = \"$v\"/" _sources/generated.nix >_sources/generated.nix.tmp
    mv _sources/generated.nix.tmp _sources/generated.nix
  else
    sed '$d' _sources/generated.nix >_sources/generated.nix.tmp
    printf '  %s = {\n    pname = "%s";\n    version = "%s";\n  };\n}\n' "$k" "$k" "$v" >>_sources/generated.nix.tmp
    mv _sources/generated.nix.tmp _sources/generated.nix
  fi
done
EOF
  chmod +x "${FX}/bump.sh"

  cp -r "${FX}/_sources" "${FX}/_baseline_sources"
  cp -r "${FX}/packages" "${FX}/_baseline_packages"

  export RDH_FLAKE_REF="path:${FX}"
  export RDH_REGISTRY="${FX}/registry.bash"
  cd "$FX" || return 1
}

teardown() {
  [ -z "${FX:-}" ] || rm -rf "${FX}"
}

# --- fixture helpers ---

hash_of() {
  local f
  f="$(mktemp)"
  printf '%s' "$1" >"$f"
  nix hash file --type sha256 --sri "$f"
  rm -f "$f"
}

version_of() {
  jq -r --arg k "$1" '.[$k].version' "${FX}/_sources/generated.json"
}

# The pin file of the fixture "locked nix-repo-base": a Nix expression for a
# version string WITHOUT the tag's leading "v" (like gomu-pin.nix).
write_pin() {
  printf 'let\n  pin = "%s";\nin\npin\n' "$1" >"${FX}/fxbase/pin.nix"
}

write_state() {
  local kv k v json='{}' nix_body=''
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    json=$(jq --arg k "$k" --arg v "$v" '.[$k] = {pname: $k, version: $v}' <<<"$json")
    nix_body+="  ${k} = {"$'\n'"    pname = \"${k}\";"$'\n'"    version = \"${v}\";"$'\n'"  };"$'\n'
  done
  printf '%s' "$(jq --indent 4 -S . <<<"$json")" >"${FX}/_sources/generated.json"
  printf '{\n%s}\n' "$nix_body" >"${FX}/_sources/generated.nix"
}

write_flake() {
  cat >"${FX}/flake.nix" <<EOF
{
  outputs =
    { self }:
    let
      sys = "${SYSTEM}";
      src = builtins.fromJSON (builtins.readFile ./_sources/generated.json);
      withDeps = [ "fresh" "aged" "stable" ];
      mkDeps =
        key:
        derivation {
          name = "${NONCE}-\${key}-deps";
          system = sys;
          builder = "${BUILDER}";
          args = [
            "-c"
            ''
              case "\$text" in
                *AGE*) echo "ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION fixture dependency was published too recently" >&2; exit 1 ;;
              esac
              printf '%s' "\$text" > "\$out"
            ''
          ];
          text = src.\${key}.version;
          outputHashMode = "flat";
          outputHashAlgo = "sha256";
          outputHash = (import ./packages/\${key}/default.nix).hash;
        };
      mkPkg =
        key:
        derivation {
          name = "${NONCE}-\${key}";
          system = sys;
          builder = "${BUILDER}";
          args = [
            "-c"
            ''
              case "\$text" in
                *BROKEN*) echo "fixture build broke" >&2; exit 1 ;;
              esac
              if [ -n "\$deps" ]; then printf '%s' "\$(< "\$deps")" > "\$out"; else printf '%s' "\$text" > "\$out"; fi
            ''
          ];
          text = src.\${key}.version;
          deps = if builtins.elem key withDeps then mkDeps key else "";
        };
    in
    {
      packages.\${sys} = builtins.listToAttrs (
        map (key: { name = key; value = mkPkg key; }) (builtins.attrNames src)
      );
    };
}
EOF
}

build_out() {
  nix build --no-link --print-out-paths "path:${FX}#$1" 2>/dev/null
}

# --- the step ---

@test "a changed source gets its dependent hash recomputed and the package builds with it" {
  # Pre-build the baseline: its dependency FOD is now in the store under the OLD
  # hash. This is the trap -- with the stale hash nix reuses that output and
  # never refetches, so only a placeholder-hash rebuild learns the new content.
  [ "$(cat "$(build_out fresh)")" = "v1" ]

  "${FX}/bump.sh" fresh=v2
  # Demonstrate the trap: the bumped package "builds" with the STALE hash, from
  # the stale cached dependency output.
  [ "$(cat "$(build_out fresh)")" = "v1" ]

  run "$SCRIPT" --gate "$(command -v true)" -- "${FX}/bump.sh" fresh=v3
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed sources: fresh"* ]]
  [[ "$output" == *"fresh: fresh builds"* ]]
  [ "$(grep -o 'sha256-[^"]*' packages/fresh/default.nix)" = "$(hash_of v3)" ]
  [[ "$(cat _sources/generated.json)" == *'"version": "v3"'* ]]
  # The package now carries the NEW dependency content, not the stale one.
  [ "$(cat "$(build_out fresh)")" = "v3" ]
  # Untouched keys keep their files byte-for-byte.
  cmp packages/stable/default.nix _baseline_packages/stable/default.nix
}

@test "an unchanged dependency set keeps its hash (got == specified is not a diff)" {
  run "$SCRIPT" --force stable
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hash unchanged"* ]]
  cmp packages/stable/default.nix _baseline_packages/stable/default.nix
}

@test "a pnpm minimumReleaseAge refusal holds that key, writes no hash, and says why" {
  run "$SCRIPT" -- "${FX}/bump.sh" aged=a2-AGE
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD aged"* ]]
  [[ "$output" == *"minimumReleaseAge"* ]]
  [[ "$output" == *"not overridden"* ]]
  # Fully reverted: no bump, no placeholder, no guessed hash.
  cmp _sources/generated.json _baseline_sources/generated.json
  cmp _sources/generated.nix _baseline_sources/generated.nix
  cmp packages/aged/default.nix _baseline_packages/aged/default.nix
  ! grep -q 'AAAAAAAA' packages/aged/default.nix
}

@test "a bumped package that no longer builds is held (the cmux class)" {
  run "$SCRIPT" -- "${FX}/bump.sh" plain=p2-BROKEN
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD plain"* ]]
  [[ "$output" == *"plain does not build after the bump"* ]]
  cmp _sources/generated.json _baseline_sources/generated.json
  cmp _sources/generated.nix _baseline_sources/generated.nix
}

@test "one held key does not block the others: good bumps land, bad ones revert" {
  run "$SCRIPT" -- "${FX}/bump.sh" fresh=v2 aged=a2-AGE plain=p2-BROKEN stable=s1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD aged"* ]]
  [[ "$output" == *"HELD plain"* ]]
  [[ "$output" != *"HELD fresh"* ]]
  [ "$(jq -r '.fresh.version' _sources/generated.json)" = "v2" ]
  [ "$(jq -r '.aged.version' _sources/generated.json)" = "a1" ]
  [ "$(jq -r '.plain.version' _sources/generated.json)" = "p1" ]
  [ "$(grep -o 'sha256-[^"]*' packages/fresh/default.nix)" = "$(hash_of v2)" ]
  cmp packages/aged/default.nix _baseline_packages/aged/default.nix
  [ "$(cat "$(build_out fresh)")" = "v2" ]
}

@test "a source with no package on this system is reported as skipped, not failed" {
  run "$SCRIPT" -- "${FX}/bump.sh" offsys=o2
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping build of not-a-package-here"* ]]
  [[ "$output" == *"NOT verified"* ]]
  [ "$(jq -r '.offsys.version' _sources/generated.json)" = "o2" ]
}

@test "a brand-new source that fails to build cannot be held and fails the step" {
  run "$SCRIPT" -- "${FX}/bump.sh" brandnew=n1-BROKEN
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"brandnew is new"* ]]
}

@test "no source change: nothing is built or touched" {
  run "$SCRIPT" -- "${FX}/bump.sh" fresh=v1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no source changed"* ]]
  cmp packages/fresh/default.nix _baseline_packages/fresh/default.nix
}

@test "a failing updater fails the step with its own exit code and refreshes nothing" {
  cat >"${FX}/fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "${FX}/fail.sh"
  run "$SCRIPT" -- "${FX}/fail.sh"
  [ "$status" -eq 7 ]
  [[ "$output" == *"updater failed with exit 7"* ]]
}

@test "a failing provenance gate stops the step before any hash is touched" {
  cat >"${FX}/gate.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${FX}/gate.sh"
  run "$SCRIPT" --gate "${FX}/gate.sh" -- "${FX}/bump.sh" fresh=v2
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to build or land the bump"* ]]
  # The framework rolls the step back; this script must not have started
  # rewriting hashes.
  cmp packages/fresh/default.nix _baseline_packages/fresh/default.nix
}

# --- pin guard (pg2-bvudh): a bump the locked input does not pin never lands ---

@test "a bump the locked input does not pin is held: source restored, reason names both versions" {
  run "$SCRIPT" -- "${FX}/bump.sh" pinned=v1.2.0
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD pinned"* ]]
  [[ "$output" == *"pinned 1.2.0 is not the version the locked fxbase pins (1.1.0"* ]]
  [[ "$output" == *"coordinated bump"* ]]
  # The previous source is restored byte-for-byte (generated.json and .nix).
  cmp _sources/generated.json _baseline_sources/generated.json
  cmp _sources/generated.nix _baseline_sources/generated.nix
  [ "$(jq -r '.pinned.version' _sources/generated.json)" = "v1.1.0" ]
}

@test "a bump whose version the locked input pins lands as before (v prefix ignored)" {
  write_pin 1.2.0
  run "$SCRIPT" -- "${FX}/bump.sh" pinned=v1.2.0
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned: 1.2.0 matches the pin in locked fxbase"* ]]
  [[ "$output" == *"pinned: pinned builds"* ]]
  [[ "$output" != *"HELD pinned"* ]]
  [ "$(jq -r '.pinned.version' _sources/generated.json)" = "v1.2.0" ]
  [ "$(cat "$(build_out pinned)")" = "v1.2.0" ]
}

@test "an unreadable pin holds the bump rather than letting it through" {
  rm -f "${FX}/fxbase/pin.nix"
  run "$SCRIPT" -- "${FX}/bump.sh" pinned=v1.2.0
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD pinned"* ]]
  [[ "$output" == *"cannot read the version pinned by fxbase:pin.nix"* ]]
  cmp _sources/generated.json _baseline_sources/generated.json
}

@test "a pin-held key does not block the others" {
  run "$SCRIPT" -- "${FX}/bump.sh" pinned=v1.2.0 fresh=v2
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HELD pinned"* ]]
  [[ "$output" != *"HELD fresh"* ]]
  [ "$(jq -r '.pinned.version' _sources/generated.json)" = "v1.1.0" ]
  [ "$(jq -r '.fresh.version' _sources/generated.json)" = "v2" ]
}
