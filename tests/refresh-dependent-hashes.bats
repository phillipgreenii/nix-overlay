#!/usr/bin/env bats
# bats file_tags=type:unit
# Pure (no nix) tests for refresh-dependent-hashes.sh: the text helpers, the
# revert logic, and the registry drift guards that keep the inventory of
# source-dependent fixed-output hashes complete (bead pg2-g39wh).
#
# The step itself -- real `nix build`, real `got:` mismatch output -- is
# exercised against a fixture flake in refresh-dependent-hashes-nix.bats.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/refresh-dependent-hashes.sh"
  # shellcheck disable=SC1090  # runtime-computed path
  source "$SCRIPT"
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# --- hash literal helpers ---

@test "rdh_get_hash: reads the literal and does not confuse hash with vendorHash" {
  cat >"${TEST_DIR}/default.nix" <<'EOF'
{
  vendorHash = "sha256-VENDOR";
  pnpmDeps = fetchPnpmDeps {
    hash = "sha256-PNPM";
  };
}
EOF
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" hash)" = "sha256-PNPM" ]
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" vendorHash)" = "sha256-VENDOR" ]
}

@test "rdh_get_hash: fails when the literal is missing or ambiguous" {
  printf 'hash = "sha256-A";\nhash = "sha256-B";\n' >"${TEST_DIR}/two.nix"
  printf '{ }\n' >"${TEST_DIR}/none.nix"
  run rdh_get_hash "${TEST_DIR}/two.nix" hash
  [ "$status" -ne 0 ]
  run rdh_get_hash "${TEST_DIR}/none.nix" hash
  [ "$status" -ne 0 ]
}

@test "rdh_set_hash: rewrites only the named literal" {
  cat >"${TEST_DIR}/default.nix" <<'EOF'
{
  vendorHash = "sha256-VENDOR";
  other = "sha256-KEEP";
  hash = "sha256-OLD";
}
EOF
  rdh_set_hash "${TEST_DIR}/default.nix" hash "sha256-NEW"
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" hash)" = "sha256-NEW" ]
  [ "$(rdh_get_hash "${TEST_DIR}/default.nix" vendorHash)" = "sha256-VENDOR" ]
  grep -qF 'other = "sha256-KEEP";' "${TEST_DIR}/default.nix"
}

# --- build log classification ---

@test "rdh_classify_log: pnpm minimumReleaseAge is its own class and beats a mismatch" {
  cat >"${TEST_DIR}/age.log" <<'EOF'
foo-pnpm-deps> ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION  mermaid@12.2.0 was published at 2026-10-13T08:32:46.000Z
error: hash mismatch in fixed-output derivation
            got:    sha256-AAAA
EOF
  [ "$(rdh_classify_log "${TEST_DIR}/age.log")" = "age" ]
}

@test "rdh_classify_log: a fixed-output mismatch is 'mismatch', anything else 'other'" {
  cat >"${TEST_DIR}/mismatch.log" <<'EOF'
error: hash mismatch in fixed-output derivation '/nix/store/x.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
EOF
  printf 'error: builder for x.drv failed with exit code 2\n' >"${TEST_DIR}/other.log"
  [ "$(rdh_classify_log "${TEST_DIR}/mismatch.log")" = "mismatch" ]
  [ "$(rdh_classify_log "${TEST_DIR}/other.log")" = "other" ]
}

@test "rdh_mismatch_pair: returns specified and got of the last mismatch" {
  cat >"${TEST_DIR}/m.log" <<'EOF'
         specified: sha256-FIRSTSPEC
            got:    sha256-FIRSTGOT
         specified: sha256-LASTSPEC
            got:    sha256-LASTGOT
EOF
  [ "$(rdh_mismatch_pair "${TEST_DIR}/m.log")" = "sha256-LASTSPEC sha256-LASTGOT" ]
}

# --- per-key revert ---

@test "rdh_restore_key: puts one key back byte-for-byte and leaves the others alone" {
  mkdir -p "${TEST_DIR}/_sources" "${TEST_DIR}/packages/a"
  RDH_BASE="${TEST_DIR}/base"
  RDH_SOURCES_DIR="${TEST_DIR}/_sources"
  # shellcheck disable=SC2034  # read by rdh_restore_key
  HASH_DEPS=(["a"]="${TEST_DIR}/packages/a/default.nix:hash:a")
  mkdir -p "${RDH_BASE}/files/${TEST_DIR}/packages/a"

  cat >"${RDH_BASE}/generated.nix" <<'EOF'
{
  a = {
    pname = "a";
    version = "1";
  };
  b = {
    pname = "b";
    version = "1";
  };
}
EOF
  jq --indent 4 -S -n '{a:{pname:"a",version:"1"},b:{pname:"b",version:"1"}}' | tr -d '\n' >"${RDH_BASE}/generated.json"
  printf 'hash = "sha256-OLD";\n' >"${RDH_BASE}/files/${TEST_DIR}/packages/a/default.nix"

  # Current tree: both keys bumped, a's hash refreshed.
  sed 's/version = "1"/version = "2"/' "${RDH_BASE}/generated.nix" >"${RDH_SOURCES_DIR}/generated.nix"
  jq --indent 4 -S '.a.version = "2" | .b.version = "2"' "${RDH_BASE}/generated.json" | tr -d '\n' >"${RDH_SOURCES_DIR}/generated.json"
  printf 'hash = "sha256-NEW";\n' >"${TEST_DIR}/packages/a/default.nix"

  rdh_restore_key a

  # a is back to the snapshot; b keeps its bump.
  [ "$(jq -r '.a.version' "${RDH_SOURCES_DIR}/generated.json")" = "1" ]
  [ "$(jq -r '.b.version' "${RDH_SOURCES_DIR}/generated.json")" = "2" ]
  awk '/^  a = \{/,/^  \};/' "${RDH_SOURCES_DIR}/generated.nix" | grep -qF 'version = "1"'
  awk '/^  b = \{/,/^  \};/' "${RDH_SOURCES_DIR}/generated.nix" | grep -qF 'version = "2"'
  [ "$(rdh_get_hash "${TEST_DIR}/packages/a/default.nix" hash)" = "sha256-OLD" ]
}

# --- registry drift guards (the inventory of source-dependent hashes) ---

@test "registry: every nvfetcher.toml key has a BUILD_ATTRS entry and vice versa" {
  local toml_keys reg_keys
  toml_keys=$(sed -nE 's/^\[([A-Za-z0-9_.-]+)\]$/\1/p' "${REPO_ROOT}/nvfetcher.toml" | sort)
  reg_keys=$(printf '%s\n' "${!BUILD_ATTRS[@]}" | sort)
  [ "$toml_keys" = "$reg_keys" ]
}

@test "registry: every BUILD_ATTRS package is exposed by flake.nix" {
  local key attr
  for key in "${!BUILD_ATTRS[@]}"; do
    for attr in ${BUILD_ATTRS[$key]}; do
      grep -qE "(^|[^A-Za-z0-9_-])${attr}([^A-Za-z0-9_-]|\$)" "${REPO_ROOT}/flake.nix" || {
        echo "BUILD_ATTRS[$key] names '$attr', which flake.nix does not mention" >&2
        return 1
      }
    done
  done
}

@test "registry: every HASH_DEPS entry points at exactly one literal in a real file" {
  local key entry file rest attr
  for key in "${!HASH_DEPS[@]}"; do
    [ -n "${BUILD_ATTRS[$key]+x}" ] || {
      echo "HASH_DEPS[$key] has no BUILD_ATTRS entry" >&2
      return 1
    }
    for entry in ${HASH_DEPS[$key]}; do
      file="${entry%%:*}"
      rest="${entry#*:}"
      attr="${rest%%:*}"
      rdh_get_hash "${REPO_ROOT}/${file}" "$attr" >/dev/null || {
        echo "HASH_DEPS[$key]: no single '$attr' literal in $file" >&2
        return 1
      }
    done
  done
}

@test "registry: every package carrying a source-dependent hash or lock is registered" {
  # The set of package dirs that hold a fixed-output hash literal, a pnpm/npm/
  # yarn dependency fetch, or a cargo lock must equal the registered set.
  local found registered key entry
  found=$(cd "${REPO_ROOT}" && grep -rlE '^[[:space:]]*(vendorHash|npmDepsHash|cargoHash|cargoSha256|yarnHash|outputHash|hash) = "sha256-|fetchPnpmDeps|fetchNpmDeps|fetchYarnDeps|fetchCargoVendor|cargoLock\.' packages --include=default.nix | xargs -n1 dirname | sort -u)
  registered=$(
    for key in "${!HASH_DEPS[@]}"; do
      for entry in ${HASH_DEPS[$key]}; do dirname "${entry%%:*}"; done
    done
    for key in "${!MANUAL_DEPS[@]}"; do dirname "${MANUAL_DEPS[$key]}"; done
  )
  registered=$(printf '%s\n' "$registered" | sort -u)
  if [ "$found" != "$registered" ]; then
    echo "package dirs with source-dependent hashes/locks: $(echo $found)" >&2
    echo "dirs registered in HASH_DEPS/MANUAL_DEPS:        $(echo $registered)" >&2
    return 1
  fi
}

@test "registry: the inventory doc names every registered hash file and lock" {
  local doc="${REPO_ROOT}/docs/update-locks-dependent-hashes.md" key entry
  [ -f "$doc" ]
  for key in "${!HASH_DEPS[@]}"; do
    for entry in ${HASH_DEPS[$key]}; do
      grep -qF "${entry%%:*}" "$doc" || {
        echo "docs/update-locks-dependent-hashes.md does not mention ${entry%%:*}" >&2
        return 1
      }
    done
  done
  for key in "${!MANUAL_DEPS[@]}"; do
    grep -qF "${MANUAL_DEPS[$key]}" "$doc" || {
      echo "docs/update-locks-dependent-hashes.md does not mention ${MANUAL_DEPS[$key]}" >&2
      return 1
    }
  done
}

@test "registry: every PIN_GUARDS entry has a BUILD_ATTRS entry, a real flake.lock input, and a doc mention" {
  local key spec input file doc="${REPO_ROOT}/docs/update-locks-dependent-hashes.md"
  [ "${#PIN_GUARDS[@]}" -gt 0 ]
  for key in "${!PIN_GUARDS[@]}"; do
    spec="${PIN_GUARDS[$key]}"
    input="${spec%%:*}"
    file="${spec#*:}"
    [ -n "${BUILD_ATTRS[$key]+x}" ] || {
      echo "PIN_GUARDS[$key] has no BUILD_ATTRS entry" >&2
      return 1
    }
    jq -e --arg i "$input" '.nodes.root.inputs[$i] as $n | ($n | type) == "string" and .nodes[$n].locked != null' "${REPO_ROOT}/flake.lock" >/dev/null || {
      echo "PIN_GUARDS[$key]: flake.lock has no locked input '$input'" >&2
      return 1
    }
    grep -qF "$file" "$doc" || {
      echo "docs/update-locks-dependent-hashes.md does not mention the pin file $file" >&2
      return 1
    }
  done
}

@test "update-locks.sh runs the nvfetcher step through refresh-dependent-hashes.sh with the provenance gate" {
  grep -qE 'refresh-dependent-hashes\.sh"? +--gate' "${REPO_ROOT}/update-locks.sh"
}

# --- per-key provenance hold (bead pg2-yfre4n), pure tier: nix and the updater are stubs ---
#
# Operator ruling 2026-10-28: "nightly updates should be able to update as much
# as possible. it isn't all or nothing." A key failing the provenance gate is
# held alone; the others land; the run exits non-zero.

# Fixture: keys a, b (each with a hash file and an earlier snapshot entry), a
# stub `nix` (a build fails with a got: mismatch while the package file holds
# the placeholder, succeeds otherwise), a stub updater bumping the keys named in
# BUMP, and a gate that fails for the keys named in GATE_FAIL.
prov_fixture() {
  mkdir -p "${TEST_DIR}/_sources" "${TEST_DIR}/packages/a" "${TEST_DIR}/packages/b" "${TEST_DIR}/bin"
  cd "${TEST_DIR}" || return 1
  jq --indent 4 -S -n '{a:{pname:"a",version:"1"},b:{pname:"b",version:"1"}}' | tr -d '\n' >_sources/generated.json
  cat >_sources/generated.nix <<'NIX'
{
  a = {
    pname = "a";
    version = "1";
  };
  b = {
    pname = "b";
    version = "1";
  };
}
NIX
  printf 'hash = "sha256-OLDA";\n' >packages/a/default.nix
  printf 'hash = "sha256-OLDB";\n' >packages/b/default.nix
  cat >bin/nix <<'EOF'
#!/usr/bin/env bash
case "$*" in
*builtins.currentSystem*)
  echo x86_64-linux
  exit 0
  ;;
*attrNames*)
  echo '["a","b","c"]'
  exit 0
  ;;
esac
if [ "$1" = build ]; then
  attr="${*: -1}"
  attr="${attr#*#}"
  if grep -q 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "packages/${attr}/default.nix"; then
    echo "         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" >&2
    echo "            got:    sha256-NEW${attr}" >&2
    exit 1
  fi
fi
exit 0
EOF
  cat >bump.sh <<'EOF'
#!/usr/bin/env bash
# bump the keys named in $BUMP (space separated) to version 2
for k in $BUMP; do
  out=$(jq --indent 4 -S --arg k "$k" '.[$k].version = "2"' _sources/generated.json)
  printf '%s' "$out" >_sources/generated.json
  sed -i.bak "/^  $k = {/,/^  };/ s/version = \"1\"/version = \"2\"/" _sources/generated.nix
  rm -f _sources/generated.nix.bak
done
EOF
  cat >gate.sh <<'EOF'
#!/usr/bin/env bash
# fail for the keys named in $GATE_FAIL
for k in $GATE_FAIL; do
  if [ "$1" = "$k" ]; then
    echo "verify-provenance: $1: hash mismatch (fixture)" >&2
    exit 1
  fi
done
echo "verify-provenance: verified: $1"
EOF
  chmod +x bin/nix bump.sh gate.sh
  PATH="${TEST_DIR}/bin:${PATH}"
  # shellcheck disable=SC2034  # read by main()
  BUILD_ATTRS=(["a"]="a" ["b"]="b")
  # shellcheck disable=SC2034
  HASH_DEPS=(["a"]="packages/a/default.nix:hash:a" ["b"]="packages/b/default.nix:hash:b")
  # shellcheck disable=SC2034
  MANUAL_DEPS=()
  # shellcheck disable=SC2034
  PIN_GUARDS=()
}

@test "provenance hold: the failing key is reverted, the passing key lands, PROVENANCE-HELD is printed, exit non-zero" {
  prov_fixture
  export BUMP="a b" GATE_FAIL="a"
  run main --gate "${TEST_DIR}/gate.sh" -- "${TEST_DIR}/bump.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROVENANCE-HELD a: "*"hash mismatch (fixture)"* ]]
  [[ "$output" != *"PROVENANCE-HELD b"* ]]
  # a: back to the snapshot (entries and hash file); b: bump and refreshed hash kept.
  [ "$(jq -r '.a.version' _sources/generated.json)" = "1" ]
  awk '/^  a = \{/,/^  \};/' _sources/generated.nix | grep -qF 'version = "1"'
  [ "$(rdh_get_hash packages/a/default.nix hash)" = "sha256-OLDA" ]
  [ "$(jq -r '.b.version' _sources/generated.json)" = "2" ]
  awk '/^  b = \{/,/^  \};/' _sources/generated.nix | grep -qF 'version = "2"'
  [ "$(rdh_get_hash packages/b/default.nix hash)" = "sha256-NEWb" ]
}

@test "provenance hold: every key passing leaves behavior unchanged and exits 0" {
  prov_fixture
  export BUMP="a b" GATE_FAIL=""
  run main --gate "${TEST_DIR}/gate.sh" -- "${TEST_DIR}/bump.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PROVENANCE-HELD"* ]]
  [ "$(jq -r '.a.version' _sources/generated.json)" = "2" ]
  [ "$(jq -r '.b.version' _sources/generated.json)" = "2" ]
  [ "$(rdh_get_hash packages/a/default.nix hash)" = "sha256-NEWa" ]
  [ "$(rdh_get_hash packages/b/default.nix hash)" = "sha256-NEWb" ]
}

@test "provenance hold: every key failing reverts all bumps, exits non-zero, one PROVENANCE-HELD line per key" {
  prov_fixture
  export BUMP="a b" GATE_FAIL="a b"
  run main --gate "${TEST_DIR}/gate.sh" -- "${TEST_DIR}/bump.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^refresh-dependent-hashes: PROVENANCE-HELD a: ' <<<"$output")" -eq 1 ]
  [ "$(grep -c '^refresh-dependent-hashes: PROVENANCE-HELD b: ' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.a.version' _sources/generated.json)" = "1" ]
  [ "$(jq -r '.b.version' _sources/generated.json)" = "1" ]
  [ "$(rdh_get_hash packages/a/default.nix hash)" = "sha256-OLDA" ]
  [ "$(rdh_get_hash packages/b/default.nix hash)" = "sha256-OLDB" ]
}

@test "provenance hold: a failing key with no earlier entry is a hard failure with an ERROR line" {
  prov_fixture
  # key c is brand new: the updater adds it, the snapshot has no entry for it.
  cat >bump.sh <<'EOF'
#!/usr/bin/env bash
out=$(jq --indent 4 -S '.c = {pname:"c",version:"1"}' _sources/generated.json)
printf '%s' "$out" >_sources/generated.json
EOF
  export GATE_FAIL="c"
  # shellcheck disable=SC2034
  BUILD_ATTRS=(["a"]="a" ["b"]="b" ["c"]="")
  run main --gate "${TEST_DIR}/gate.sh" -- "${TEST_DIR}/bump.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR c is new (no earlier entry to restore) and cannot be held: provenance failed"* ]]
  [[ "$output" != *"PROVENANCE-HELD c"* ]]
}

@test "provenance hold: --held-report records the held lines and exits 0 so the framework keeps the other keys" {
  prov_fixture
  export BUMP="a b" GATE_FAIL="a"
  run main --gate "${TEST_DIR}/gate.sh" --held-report "${TEST_DIR}/held.txt" -- "${TEST_DIR}/bump.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q '^PROVENANCE-HELD a: ' "${TEST_DIR}/held.txt"
  [ "$(wc -l <"${TEST_DIR}/held.txt")" -eq 1 ]
  [ "$(jq -r '.b.version' _sources/generated.json)" = "2" ]
}

@test "docs: nothing says a provenance failure rolls back the whole run" {
  ! grep -nE 'rolls everything back|step fails, framework rolls back|refusing to build or land' \
    "${REPO_ROOT}/refresh-dependent-hashes.sh" "${REPO_ROOT}/docs/update-locks-dependent-hashes.md" \
    "${REPO_ROOT}/README.md" "${REPO_ROOT}/verify-provenance.sh"
}
