#!/usr/bin/env bash
# Refresh (or hold) the fixed-output hashes that DEPEND on an nvfetcher source
# bump (bead pg2-g39wh).
#
# Problem: nvfetcher moves a package's source (rev + source SRI) but the hashes
# derived FROM that source -- fetchPnpmDeps `hash`, buildGoModule `vendorHash`,
# ... -- stay at their old values. When upstream changed its dependencies the
# auto-landed bump then breaks the system build (mermaid-live-editor,
# 2026-10-13: ERR_PNPM_NO_OFFLINE_TARBALL), and a bumped package can also just
# stop building (cmux 0.65.1, 2026-10-13, pg2-ybbs8).
#
# This script wraps the nvfetcher step (update-locks.sh runs it as the step
# command) and, for every source whose entry in _sources/generated.json
# changed:
#
#   1. GATE   Runs the optional --gate command (verify-provenance.sh) once per
#             changed key, with the key as its only argument, BEFORE any build,
#             so no unverified binary artifact is unpacked/built first. A key
#             whose gate fails is HELD alone (bump reverted, exactly like step
#             4), a `PROVENANCE-HELD <key>: <reason>` line is printed, and the
#             other keys continue and land (bead pg2-yfre4n). The run exits
#             non-zero so it is visibly flagged (see --held-report).
#   2. REFRESH  For each dependent fixed-output hash (HASH_DEPS): writes a
#             placeholder hash, builds the package, and takes nix's own
#             `got:` value as the new hash. A placeholder is REQUIRED -- with the
#             stale hash the FOD output path already exists in the store, nix
#             never refetches, and the stale dependency tree is silently reused
#             (the very failure above). The `specified:` value in the mismatch
#             MUST equal the placeholder, so the `got:` of an unrelated fixed-
#             output derivation (e.g. the source itself) is never written.
#   3. VERIFY Builds every package registered for the key (BUILD_ATTRS) with the
#             refreshed hashes. A package that does not build is not landed.
#   4. HOLD   When 2 or 3 fails, that key's bump is reverted (its _sources entry
#             in generated.json AND generated.nix, and its hash files, restored
#             from the pre-update snapshot) and the run CONTINUES with the other
#             keys: one broken upstream must not freeze every other update. Held
#             keys are retried automatically on the next run.
#
# PIN GUARD (bead pg2-bvudh): a key registered in PIN_GUARDS is HELD before any
# hash is rewritten or anything is built when its source version is not the
# version pinned by the locked flake input (gomu vs nix-repo-base's
# gomu-pin.nix; the two need a coordinated bump, spec W16). See the "Pin guard"
# section of docs/update-locks-dependent-hashes.md.
#
# pnpm minimumReleaseAge (supply-chain policy that rejects dependencies
# published within about a day): a build that dies with
# ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION is reported as such and the key is
# HELD. The policy is NEVER overridden and no guessed hash is written; the next
# run retries once the dependency has aged (bead pg2-kwuw0).
#
# Sources whose key is absent from the snapshot (brand-new) cannot be reverted
# to anything, so a failure there (provenance included) exits 1.
#
# Usage:
#   refresh-dependent-hashes.sh [--gate CMD] [--held-report FILE] [--force KEY]... [-- UPDATER [ARGS...]]
#
#   --gate CMD     run `CMD KEY` for each changed key after UPDATER and before
#                  any build; a non-zero exit holds that key only.
#   --held-report FILE
#                  write the PROVENANCE-HELD lines to FILE and exit 0 for them
#                  (a hard failure still exits 1). update-locks.sh uses this:
#                  its framework rolls back every change of a step that exits
#                  non-zero, so a later step flags the run from FILE instead.
#                  Without it a provenance hold exits 1.
#   --force KEY    treat KEY as changed even if UPDATER did not change it. Use it
#                  to recompute a dependent hash by hand
#                  (`./refresh-dependent-hashes.sh --force pint`).
#   -- UPDATER...  the command that bumps sources (nvfetcher); omit it to only
#                  reconcile --force'd keys.
#
# Environment (all optional; tests use them to run the REAL step on a fixture):
#   RDH_FLAKE_REF      flake ref the builds use                (default: .)
#   RDH_SOURCES_DIR    nvfetcher output dir                    (default: _sources)
#   RDH_LOCK_FILE      lock file the PIN_GUARDS read the locked input from (default: flake.lock)
#   RDH_REGISTRY       bash file sourced after the built-in registry below to
#                      replace BUILD_ATTRS / HASH_DEPS / MANUAL_DEPS / PIN_GUARDS
#
# Inventory of source-dependent inputs: docs/update-locks-dependent-hashes.md.
set -euo pipefail

# --- registry (keep in sync with docs/update-locks-dependent-hashes.md; the bats
# --- suite fails when a nvfetcher.toml key or a hash-bearing package is missing)

# nvfetcher key -> space-separated flake `packages.<system>` attrs built after a
# bump. Attrs not exposed on the current system (the aarch64-darwin-only
# packages on linux) are skipped with a log line, not failed. An empty value
# means "registered, but nothing to build" (none today).
declare -gA BUILD_ATTRS=(
  ["bat-gherkin-syntax"]="bat-gherkin-syntax"
  ["bunny"]="yaziPlugins-bunny"
  ["cmux"]="cmux"
  ["eclipse-java"]="eclipse-java eclipse-with-gradleimport"
  ["gh-stack"]="gh-stack"
  ["glowm"]="glowm"
  ["gomu"]="gomu"
  ["icons-brew"]="yaziPlugins-icons-brew"
  ["logseq"]="logseq"
  ["lombok"]="eclipse-with-gradleimport"
  ["mdr-rs"]="mdr-rs"
  ["mermaid-ink"]="mermaid-ink"
  ["mermaid-live-editor"]="mermaid-live-editor"
  ["pint"]="pint"
  ["tmux-mouse-swipe"]="tmux-mouse-swipe"
  ["tmux-nerd-font-window-name"]="tmux-nerd-font-window-name"
  ["tmux-open-nvim"]="tmux-open-nvim"
)

# nvfetcher key -> space-separated "<file>:<hash attribute>:<flake attr>"
# entries: the fixed-output hash literal that depends on the key's source, and
# the package to build to recompute it.
declare -gA HASH_DEPS=(
  ["gh-stack"]="packages/gh-stack/default.nix:vendorHash:gh-stack"
  ["glowm"]="packages/glowm/default.nix:vendorHash:glowm"
  ["gomu"]="packages/gomu/default.nix:vendorHash:gomu"
  ["mermaid-ink"]="packages/mermaid-ink/default.nix:hash:mermaid-ink"
  ["mermaid-live-editor"]="packages/mermaid-live-editor/default.nix:hash:mermaid-live-editor"
  ["pint"]="packages/pint/default.nix:vendorHash:pint"
)

# nvfetcher key -> source-dependent input that is NOT a hash literal and so is
# not refreshed here: a hand-copied upstream lock file. A bump that breaks it
# fails the VERIFY build and is HELD (never landed).
declare -gA MANUAL_DEPS=(
  ["mdr-rs"]="packages/mdr-rs/Cargo.lock"
)

# nvfetcher key -> "<flake input>:<file>": the source's version MUST equal the
# version recorded in <file> of that flake input AS LOCKED in flake.lock
# (bead pg2-bvudh). A bump the locked input does not pin is HELD, never landed:
# gomu v0.3.0 landed while nix-repo-base's gomu-pin.nix still said 0.2.1 and
# home/pg-go-mutate's eval assertion broke `pn workspace build` (2026-10-19).
# The pin file is a Nix expression evaluating to a version string WITHOUT the
# tag's leading "v"; a leading "v" on the source version is ignored here.
declare -gA PIN_GUARDS=(
  ["gomu"]="phillipgreenii-nix-base:modules/pg-go-mutate/pg-go-mutate/gomu-pin.nix"
)

# Placeholder == nixpkgs' lib.fakeHash.
RDH_PLACEHOLDER='sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

if [ -n "${RDH_REGISTRY:-}" ]; then
  # shellcheck disable=SC1090  # runtime-computed path (test registry)
  source "$RDH_REGISTRY"
fi

rdh_log() { echo "refresh-dependent-hashes: $*"; }

# --- hash literal helpers -----------------------------------------------------

# Print the value of `<attr> = "sha256-...";` in <file>; fail unless EXACTLY
# one such line exists (a second match would make the rewrite ambiguous).
rdh_get_hash() {
  local file="$1" attr="$2" matches
  matches=$(sed -nE "s|^[[:space:]]*${attr} = \"(sha256-[^\"]*)\";.*|\1|p" "$file")
  [ -n "$matches" ] && [ "$(printf '%s\n' "$matches" | wc -l)" -eq 1 ] || return 1
  printf '%s\n' "$matches"
}

# Rewrite the value of `<attr> = "sha256-...";` in <file> in place.
rdh_set_hash() {
  local file="$1" attr="$2" value="$3" tmp
  tmp=$(mktemp)
  sed -E "s|^([[:space:]]*${attr} = \")sha256-[^\"]*(\";)|\1${value}\2|" "$file" >"$tmp"
  cat "$tmp" >"$file" # keep the original file's mode/inode
  rm -f "$tmp"
}

# --- build log classification --------------------------------------------------

# Classify a failed `nix build` log: age | mismatch | other.
#   age       pnpm's minimumReleaseAge supply-chain policy rejected a dependency
#             published too recently. Checked FIRST: it is a policy refusal, not
#             a hash problem, and must never be "fixed" by guessing.
#   mismatch  nix reported a fixed-output hash mismatch (`specified:`/`got:`).
rdh_classify_log() {
  local log="$1"
  if grep -qE 'ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION|minimumReleaseAge' "$log"; then
    echo age
  elif grep -qE '^[[:space:]]*got:[[:space:]]+sha256-' "$log"; then
    echo mismatch
  else
    echo other
  fi
}

# Print "<specified> <got>" of the LAST fixed-output mismatch in the log.
rdh_mismatch_pair() {
  awk '
    /^[[:space:]]*specified:[[:space:]]+sha256-/ { spec = $2 }
    /^[[:space:]]*got:[[:space:]]+sha256-/       { got = $2 }
    END { if (spec != "" && got != "") print spec, got }
  ' "$1"
}

# --- per-key revert ------------------------------------------------------------

# Replace key's block in a generated.nix with its block from the snapshot copy.
# Blocks are nvfetcher's `  <key> = {` ... `  };` (two-space indent).
rdh_restore_nix_block() {
  local key="$1" base_file="$2" cur_file="$3" blockfile tmp
  blockfile=$(mktemp)
  awk -v k="$key" '
    $0 == "  " k " = {" { inb = 1 }
    inb { print }
    inb && $0 == "  };" { exit }
  ' "$base_file" >"$blockfile"
  if [ ! -s "$blockfile" ]; then
    rm -f "$blockfile"
    return 1
  fi
  tmp=$(mktemp)
  # The block goes through a file: BSD awk rejects newlines inside -v values.
  awk -v k="$key" -v blockfile="$blockfile" '
    $0 == "  " k " = {" {
      while ((getline line < blockfile) > 0) print line
      skip = 1
      next
    }
    skip && $0 == "  };" { skip = 0; next }
    skip { next }
    { print }
  ' "$cur_file" >"$tmp"
  cat "$tmp" >"$cur_file"
  rm -f "$tmp" "$blockfile"
}

# Replace key's entry in a generated.json with its entry from the snapshot copy
# (nvfetcher's format: 4-space indent, sorted keys, no trailing newline).
rdh_restore_json_entry() {
  local key="$1" base_file="$2" cur_file="$3" out
  out=$(jq --indent 4 -S --arg k "$key" --slurpfile b "$base_file" '.[$k] = $b[0][$k]' "$cur_file")
  printf '%s' "$out" >"$cur_file"
}

# Revert one key to its snapshot state: both generated files and its hash files.
rdh_restore_key() {
  local key="$1" entry file
  rdh_restore_json_entry "$key" "$RDH_BASE/generated.json" "$RDH_SOURCES_DIR/generated.json"
  rdh_restore_nix_block "$key" "$RDH_BASE/generated.nix" "$RDH_SOURCES_DIR/generated.nix"
  for entry in ${HASH_DEPS[$key]:-}; do
    file="${entry%%:*}"
    cat "$RDH_BASE/files/$file" >"$file"
  done
}

# --- pin guard -----------------------------------------------------------------

# Print the version string a flake input pins, read from <file> of that input AS
# LOCKED in the lock file (RDH_LOCK_FILE, default flake.lock). Fetches the exact
# locked tree with builtins.fetchTree, so it reads the same bytes the consumer
# build will see, and is offline whenever that tree is already in the store
# (a github lock carries a narHash). Prints nothing and fails when the input,
# the tree or the file cannot be read.
rdh_read_pin() {
  local input="$1" file="$2" lock="${RDH_LOCK_FILE:-flake.lock}" node locked
  [ -f "$lock" ] || return 1
  node=$(jq -er --arg i "$input" '.nodes.root.inputs[$i] | strings' "$lock") || return 1
  locked=$(jq -ce --arg n "$node" '.nodes[$n].locked' "$lock") || return 1
  # shellcheck disable=SC2016  # ${...} is Nix string interpolation, not shell
  RDH_PIN_LOCKED="$locked" RDH_PIN_FILE="$file" nix eval --impure --raw --expr '
    let
      src = builtins.fetchTree (builtins.fromJSON (builtins.getEnv "RDH_PIN_LOCKED"));
    in
    import "${src}/${builtins.getEnv "RDH_PIN_FILE"}"
  ' 2>/dev/null
}

# Check one key against its PIN_GUARDS entry. Sets HOLD_REASON and returns 1
# when the key's source version is not the version the locked input pins (or the
# pin cannot be read: fail closed, an unreadable pin is not "matches").
rdh_check_pin() {
  local key="$1" spec input file version pin
  spec="${PIN_GUARDS[$key]:-}"
  [ -n "$spec" ] || return 0
  input="${spec%%:*}"
  file="${spec#*:}"
  version=$(jq -r --arg k "$key" '.[$k].version' "$RDH_SOURCES_DIR/generated.json")
  version="${version#v}"
  if ! pin=$(rdh_read_pin "$input" "$file") || [ -z "$pin" ]; then
    HOLD_REASON="cannot read the version pinned by $input:$file from ${RDH_LOCK_FILE:-flake.lock}; not landing a $key bump it cannot be checked against"
    return 1
  fi
  if [ "$version" != "$pin" ]; then
    HOLD_REASON="$key $version is not the version the locked $input pins ($pin, $file); a coordinated bump is needed: set the pin to $version in $input, push it, relock this flake ($input), then rerun (the next run retries this bump)"
    return 1
  fi
  rdh_log "$key: $version matches the pin in locked $input ($file)"
}

# --- build helper --------------------------------------------------------------

# Build packages.<system>.<attr>; full build logs go to <log> (-L) so the
# classification sees pnpm's own error line, not just nix's last 25 lines.
rdh_build() {
  local attr="$1" log="$2"
  nix build --no-link -L "${RDH_FLAKE_REF}#${attr}" >/dev/null 2>"$log"
}

# --- per-key processing --------------------------------------------------------

HOLD_REASON=""

# Recompute one dependent hash. Sets HOLD_REASON and returns 1 when the hash
# cannot be computed (the caller holds the key).
rdh_refresh_hash() {
  local file="$1" attr="$2" flake_attr="$3" old log spec got
  if ! old=$(rdh_get_hash "$file" "$attr"); then
    HOLD_REASON="cannot find exactly one '$attr = \"sha256-...\";' line in $file"
    return 1
  fi
  rdh_set_hash "$file" "$attr" "$RDH_PLACEHOLDER"
  log=$(mktemp)
  if rdh_build "$flake_attr" "$log"; then
    HOLD_REASON="$flake_attr built with the placeholder hash in $file; refusing to trust that"
    rm -f "$log"
    return 1
  fi
  case "$(rdh_classify_log "$log")" in
  age)
    HOLD_REASON="pnpm minimumReleaseAge: $(grep -m1 -E 'ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION|minimumReleaseAge' "$log" | sed -E 's/^[^ ]*> //') (a dependency was published too recently; the policy is not overridden, the bump is retried on the next run)"
    rm -f "$log"
    return 1
    ;;
  mismatch)
    read -r spec got < <(rdh_mismatch_pair "$log")
    if [ "$spec" != "$RDH_PLACEHOLDER" ]; then
      HOLD_REASON="fixed-output mismatch in $flake_attr was not the placeholder in $file (specified $spec); not writing its got: hash"
      rm -f "$log"
      return 1
    fi
    rdh_set_hash "$file" "$attr" "$got"
    if [ "$got" = "$old" ]; then
      rdh_log "  $file: $attr unchanged ($got)"
    else
      rdh_log "  $file: $attr $old -> $got"
    fi
    ;;
  *)
    HOLD_REASON="$flake_attr failed before its hash could be computed: $(tail -n 15 "$log" | tr '\n' '|')"
    rm -f "$log"
    return 1
    ;;
  esac
  rm -f "$log"
}

# Refresh hashes (once) and build-verify one changed key. Returns 1 (with
# HOLD_REASON set) when the key must be held.
rdh_process_key() {
  local key="$1" attrs entry file rest attr flake_attr log built=0
  read -r -a attrs <<<"${BUILD_ATTRS[$key]:-}"

  # Cheapest check first: a version the locked input does not pin is held before
  # any hash is rewritten or anything is built.
  rdh_check_pin "$key" || return 1

  if [ -z "${BUILD_ATTRS[$key]+x}" ]; then
    rdh_log "$key: WARNING no build check registered in BUILD_ATTRS; its bump is NOT verified"
    return 0
  fi

  if [ -n "${MANUAL_DEPS[$key]:-}" ]; then
    rdh_log "$key: ${MANUAL_DEPS[$key]} is a hand-copied lock, not refreshed here; the build below decides whether the bump lands"
  fi

  if [ -z "${RDH_REFRESHED[$key]:-}" ]; then
    for entry in ${HASH_DEPS[$key]:-}; do
      file="${entry%%:*}"
      rest="${entry#*:}"
      attr="${rest%%:*}"
      flake_attr="${rest#*:}"
      if ! grep -qxF "$flake_attr" <<<"$RDH_AVAILABLE"; then
        rdh_log "$key: $flake_attr is not built on $RDH_SYSTEM; hash in $file NOT refreshed"
        continue
      fi
      rdh_refresh_hash "$file" "$attr" "$flake_attr" || return 1
    done
    RDH_REFRESHED[$key]=1
  fi

  for flake_attr in "${attrs[@]}"; do
    if ! grep -qxF "$flake_attr" <<<"$RDH_AVAILABLE"; then
      rdh_log "$key: skipping build of $flake_attr (not a $RDH_SYSTEM package)"
      continue
    fi
    log=$(mktemp)
    if ! rdh_build "$flake_attr" "$log"; then
      HOLD_REASON="$flake_attr does not build after the bump: $(tail -n 15 "$log" | tr '\n' '|')"
      rm -f "$log"
      return 1
    fi
    rm -f "$log"
    built=1
    rdh_log "$key: $flake_attr builds"
  done
  [ "$built" -eq 1 ] || rdh_log "$key: nothing was built on $RDH_SYSTEM; the bump is NOT verified"
}

# Snapshot everything a hold may need to restore.
rdh_snapshot() {
  local key entry file
  mkdir -p "$RDH_BASE/files"
  cp "$RDH_SOURCES_DIR/generated.json" "$RDH_BASE/generated.json"
  cp "$RDH_SOURCES_DIR/generated.nix" "$RDH_BASE/generated.nix"
  for key in "${!HASH_DEPS[@]}"; do
    for entry in ${HASH_DEPS[$key]}; do
      file="${entry%%:*}"
      mkdir -p "$RDH_BASE/files/$(dirname "$file")"
      cp "$file" "$RDH_BASE/files/$file"
    done
  done
}

rdh_usage() {
  echo "Usage: $0 [--gate CMD] [--held-report FILE] [--force KEY]... [-- UPDATER [ARGS...]]"
}

main() {
  local gate="" key rc held_report=""
  local -a forced=() changed=() active=() held=() verified=() prov_held=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --held-report)
      held_report="${2:?--held-report needs a file}"
      shift 2
      ;;
    --gate)
      gate="${2:?--gate needs a command}"
      shift 2
      ;;
    --force)
      forced+=("${2:?--force needs a key}")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h | --help)
      rdh_usage
      return 0
      ;;
    *)
      rdh_usage >&2
      return 2
      ;;
    esac
  done

  RDH_FLAKE_REF="${RDH_FLAKE_REF:-.}"
  RDH_SOURCES_DIR="${RDH_SOURCES_DIR:-_sources}"
  RDH_BASE=$(mktemp -d)
  # shellcheck disable=SC2064  # expand-now is intentional: RDH_BASE is set just above.
  trap "rm -rf '$RDH_BASE'" EXIT
  declare -gA RDH_REFRESHED=()

  rdh_snapshot

  if [ "$#" -gt 0 ]; then
    rc=0
    "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "refresh-dependent-hashes: updater failed with exit $rc; nothing refreshed" >&2
      return "$rc"
    fi
  fi

  # Keys whose generated.json entry differs from the snapshot (jq -S: stable).
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if [ "$(jq -cS --arg k "$key" '.[$k]' "$RDH_BASE/generated.json")" != "$(jq -cS --arg k "$key" '.[$k]' "$RDH_SOURCES_DIR/generated.json")" ]; then
      changed+=("$key")
    fi
  done < <(jq -r 'keys[]' "$RDH_SOURCES_DIR/generated.json")
  for key in "${forced[@]}"; do
    [[ " ${changed[*]} " == *" $key "* ]] || changed+=("$key")
  done

  if [ "${#changed[@]}" -eq 0 ]; then
    rdh_log "no source changed; nothing to refresh or verify."
    return 0
  fi
  rdh_log "changed sources: ${changed[*]}"

  # Provenance gate, per key, BEFORE any build: a failing key is held (restored
  # from the snapshot) and the others continue. A key with no earlier entry
  # cannot be held and stays a hard failure.
  local hard_fail=0 gate_out gate_reason
  if [ -n "$gate" ]; then
    active=()
    for key in "${changed[@]}"; do
      rdh_log "running gate before any build: $gate $key"
      if gate_out=$("$gate" "$key" 2>&1); then
        printf '%s\n' "$gate_out"
        active+=("$key")
        continue
      fi
      printf '%s\n' "$gate_out" >&2
      gate_reason="gate '$gate' failed for $key: $(printf '%s\n' "$gate_out" | grep -v '^[[:space:]]*$' | tail -n 5 | tr '\n' '|')"
      if [ "$(jq -e --arg k "$key" 'has($k)' "$RDH_BASE/generated.json")" != "true" ]; then
        echo "refresh-dependent-hashes: ERROR $key is new (no earlier entry to restore) and cannot be held: provenance failed: $gate_reason" >&2
        hard_fail=1
        continue
      fi
      rdh_restore_key "$key"
      held+=("$key")
      prov_held+=("PROVENANCE-HELD $key: $gate_reason")
      echo "refresh-dependent-hashes: PROVENANCE-HELD $key: $gate_reason (bump reverted, retried next run)" >&2
    done
    changed=("${active[@]}")
  fi

  RDH_SYSTEM=$(nix eval --impure --raw --expr builtins.currentSystem)
  RDH_AVAILABLE=$(nix eval --json "${RDH_FLAKE_REF}#packages.${RDH_SYSTEM}" --apply builtins.attrNames | jq -r '.[]')

  # Process every still-active key; a hold may invalidate an earlier key's
  # verification (packages composed from several sources, e.g. eclipse-java +
  # lombok), so after any hold re-verify the survivors until a pass is clean.
  active=("${changed[@]}")
  local held_in_pass remaining
  while [ "${#active[@]}" -gt 0 ]; do
    held_in_pass=0
    remaining=()
    for key in "${active[@]}"; do
      HOLD_REASON=""
      if rdh_process_key "$key"; then
        remaining+=("$key")
        continue
      fi
      held_in_pass=1
      if [ "$(jq -e --arg k "$key" 'has($k)' "$RDH_BASE/generated.json")" != "true" ]; then
        echo "refresh-dependent-hashes: ERROR $key is new (no earlier entry to restore) and cannot be held: $HOLD_REASON" >&2
        hard_fail=1
        continue
      fi
      rdh_restore_key "$key"
      held+=("$key")
      echo "refresh-dependent-hashes: HELD $key (bump reverted, retried next run): $HOLD_REASON"
    done
    active=("${remaining[@]}")
    [ "$held_in_pass" -eq 1 ] || break
  done
  verified=("${active[@]}")

  rdh_log "summary: verified/refreshed: ${verified[*]:-none}; held: ${held[*]:-none}"
  if [ "${#prov_held[@]}" -gt 0 ]; then
    local line
    for line in "${prov_held[@]}"; do
      echo "refresh-dependent-hashes: summary: $line" >&2
    done
    if [ -n "$held_report" ]; then
      printf '%s\n' "${prov_held[@]}" >"$held_report"
    fi
  fi
  [ "$hard_fail" -eq 0 ] || return 1
  # A provenance hold flags the run non-zero, but the other keys have landed.
  # With --held-report the caller (update-locks.sh) flags the run itself, in a
  # later step, because the framework rolls back EVERY change of a step that
  # exits non-zero.
  if [ "${#prov_held[@]}" -gt 0 ] && [ -z "$held_report" ]; then
    return 1
  fi
  return 0
}

# Only run when executed directly; sourcing (bats) defines the functions only.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
