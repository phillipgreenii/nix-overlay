#!/usr/bin/env bash
# Standalone developer utility — not Nix-wrapped intentionally
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
--ci)
  export UL_CI_MODE=true
  shift
  ;;
-h | --help)
  echo "Usage: $0 [--ci]"
  echo "  --ci  Disable laptop-only checks (nix daemon health, time-based cache)"
  exit 0
  ;;
"") ;;
*)
  echo "Unknown argument: $1" >&2
  echo "Usage: $0 [--ci]" >&2
  exit 1
  ;;
esac

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/scripts/update-locks-lib.bash"
ul_setup "phillipgreenii-nix-overlay" "${SCRIPT_DIR}"

# Update a tmux plugin's sha256 and version in sync with its branch tip.
# Each plugin lives in its own file: packages/<plugin-name>/default.nix.
# shellcheck disable=SC2329
update_tmux_plugin() {
  local plugin_name="$1"
  local owner="$2"
  local repo="$3"
  local branch="${4:-main}"
  local nix_file="${SCRIPT_DIR}/packages/${plugin_name}/default.nix"

  echo "==> Updating tmux plugin ${plugin_name}..."

  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)

  local new_rev new_hash
  new_rev=$(printf '%s' "$prefetch_json" | jq -r '.rev')
  new_hash=$(printf '%s' "$prefetch_json" | jq -r '.hash')

  local current_hash
  current_hash=$(grep 'sha256 = ' "$nix_file" | sed 's/.*sha256 = "\([^"]*\)".*/\1/')

  if [[ $new_hash == "$current_hash" ]]; then
    echo "  ✓ ${plugin_name} already up to date (${new_rev:0:7})"
    return
  fi

  local new_date
  new_date=$(curl -sf "https://api.github.com/repos/${owner}/${repo}/commits/${new_rev}" |
    jq -r '.commit.committer.date' | sed 's/T.*//')

  echo "  ${plugin_name}: updated to ${new_rev:0:7} (${new_date})"

  sed -i "s|version = \"unstable-[^\"]*\";|version = \"unstable-${new_date}\";|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
}

# Update a bat syntax definition's sha256 and date comment in sync with branch tip.
# shellcheck disable=SC2329
update_bat_syntax() {
  local syntax_name="$1"
  local owner="$2"
  local repo="$3"
  local branch="${4:-main}"
  local nix_file="${SCRIPT_DIR}/packages/bat-gherkin-syntax/default.nix"

  echo "==> Updating bat syntax ${syntax_name}..."

  local prefetch_json
  prefetch_json=$(nix run nixpkgs#nix-prefetch-github -- --json --rev "$branch" "$owner" "$repo" 2>/dev/null)

  local new_rev new_hash
  new_rev=$(printf '%s' "$prefetch_json" | jq -r '.rev')
  new_hash=$(printf '%s' "$prefetch_json" | jq -r '.hash')

  local current_hash
  current_hash=$(grep 'sha256 = ' "$nix_file" | sed 's/.*sha256 = "\([^"]*\)".*/\1/')

  if [[ $new_hash == "$current_hash" ]]; then
    echo "  ✓ ${syntax_name} already up to date (${new_rev:0:7})"
    return
  fi

  local new_date
  new_date=$(curl -sf "https://api.github.com/repos/${owner}/${repo}/commits/${new_rev}" |
    jq -r '.commit.committer.date' | sed 's/T.*//')

  echo "  ${syntax_name}: updated to ${new_rev:0:7} (${new_date})"

  sed -i "s|# last updated: unstable-[0-9-]*|# last updated: unstable-${new_date}|" "$nix_file"
  sed -i "s|sha256 = \"sha256-[^\"]*\";|sha256 = \"${new_hash}\";|" "$nix_file"
}

ul_run_step "update-cmux" \
  "update-locks: update cmux" \
  nix run .#update-cmux -- "${SCRIPT_DIR}"

ul_run_step "update-c9watch" \
  "update-locks: update c9watch" \
  nix run .#update-c9watch -- "${SCRIPT_DIR}"

ul_run_step "update-beads-web" \
  "update-locks: update beads-web" \
  nix run .#update-beads-web -- "${SCRIPT_DIR}"

ul_run_step "tmux-open-nvim" \
  "update-locks: update tmux-open-nvim" \
  update_tmux_plugin "tmux-open-nvim" "trevarj" "tmux-open-nvim" "master"

ul_run_step "tmux-mouse-swipe" \
  "update-locks: update tmux-mouse-swipe" \
  update_tmux_plugin "tmux-mouse-swipe" "jaclu" "tmux-mouse-swipe" "main"

ul_run_step "tmux-nerd-font-window-name" \
  "update-locks: update tmux-nerd-font-window-name" \
  update_tmux_plugin "tmux-nerd-font-window-name" "joshmedeski" "tmux-nerd-font-window-name" "main"

ul_run_step "bat-gherkin-syntax" \
  "update-locks: update bat gherkin syntax" \
  update_bat_syntax "Gherkin" "keith-hall" "SublimeGherkinSyntax" "master"

ul_run_step "nix-flake-update" \
  "update-locks: update nix flake.lock" \
  nix flake update

ul_finalize
