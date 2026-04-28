#!/usr/bin/env bash
# Update c9watch package to latest GitHub release.
# Called from update-locks.sh before nix flake update.
#
# Checks GitHub for latest release, downloads all four artifacts to get
# hashes, and updates version and hashes in packages/c9watch/gui.nix and
# packages/c9watch/cli.nix if a newer release is available.

REPO_ROOT="${1:-.}"
GUI_TARGET="${REPO_ROOT}/packages/c9watch/gui.nix"
CLI_TARGET="${REPO_ROOT}/packages/c9watch/cli.nix"

if [[ ! -f $GUI_TARGET ]]; then
  echo "Error: packages/c9watch/gui.nix not found at $GUI_TARGET" >&2
  exit 1
fi

echo "Checking for c9watch updates..."

CURRENT_VERSION=$(grep 'version = ' "$GUI_TARGET" | head -1 | sed 's/.*version = "\([^"]*\)".*/\1/')

if [[ -z $CURRENT_VERSION ]]; then
  echo "  Error: Could not find current c9watch version in $GUI_TARGET" >&2
  exit 1
fi

echo "  Fetching latest release info..."
GH_HEADERS=()
if [[ -n ${GH_TOKEN:-} ]]; then
  GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")
fi
LATEST_TAG=$(curl -s "${GH_HEADERS[@]}" https://api.github.com/repos/minchenlee/c9watch/releases/latest | jq -r '.tag_name')
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z $LATEST_VERSION || $LATEST_VERSION == "null" ]]; then
  echo "  Error: Could not fetch latest release from GitHub" >&2
  exit 1
fi

if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
  echo "  c9watch is up to date ($CURRENT_VERSION)"
  exit 0
fi

echo "  New c9watch release detected: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Fetching artifact hashes (downloading ~20 MB per artifact)..."

GUI_AARCH64_URL="https://github.com/minchenlee/c9watch/releases/download/v${LATEST_VERSION}/c9watch_v${LATEST_VERSION}_aarch64.app.tar.gz"
GUI_X86_64_URL="https://github.com/minchenlee/c9watch/releases/download/v${LATEST_VERSION}/c9watch_v${LATEST_VERSION}_x86_64.app.tar.gz"
CLI_AARCH64_URL="https://github.com/minchenlee/c9watch/releases/download/v${LATEST_VERSION}/c9watch-cli-aarch64-apple-darwin.tar.gz"
CLI_X86_64_URL="https://github.com/minchenlee/c9watch/releases/download/v${LATEST_VERSION}/c9watch-cli-x86_64-apple-darwin.tar.gz"

RAW_GUI_AARCH64=$(nix-prefetch-url "$GUI_AARCH64_URL" 2>/dev/null)
[[ -z $RAW_GUI_AARCH64 ]] && {
  echo "  Error: Could not prefetch $GUI_AARCH64_URL" >&2
  exit 1
}
RAW_GUI_X86_64=$(nix-prefetch-url "$GUI_X86_64_URL" 2>/dev/null)
[[ -z $RAW_GUI_X86_64 ]] && {
  echo "  Error: Could not prefetch $GUI_X86_64_URL" >&2
  exit 1
}
RAW_CLI_AARCH64=$(nix-prefetch-url "$CLI_AARCH64_URL" 2>/dev/null)
[[ -z $RAW_CLI_AARCH64 ]] && {
  echo "  Error: Could not prefetch $CLI_AARCH64_URL" >&2
  exit 1
}
RAW_CLI_X86_64=$(nix-prefetch-url "$CLI_X86_64_URL" 2>/dev/null)
[[ -z $RAW_CLI_X86_64 ]] && {
  echo "  Error: Could not prefetch $CLI_X86_64_URL" >&2
  exit 1
}

GUI_HASH_AARCH64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_GUI_AARCH64" 2>/dev/null || echo "sha256-$RAW_GUI_AARCH64")
GUI_HASH_X86_64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_GUI_X86_64" 2>/dev/null || echo "sha256-$RAW_GUI_X86_64")
CLI_HASH_AARCH64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_CLI_AARCH64" 2>/dev/null || echo "sha256-$RAW_CLI_AARCH64")
CLI_HASH_X86_64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_CLI_X86_64" 2>/dev/null || echo "sha256-$RAW_CLI_X86_64")

echo "  Updating packages/c9watch/gui.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$GUI_TARGET"
sed -i "s|guiHashAarch64 = \"sha256-[^\"]*\"|guiHashAarch64 = \"$GUI_HASH_AARCH64\"|" "$GUI_TARGET"
sed -i "s|guiHashX86_64 = \"sha256-[^\"]*\"|guiHashX86_64 = \"$GUI_HASH_X86_64\"|" "$GUI_TARGET"

echo "  Updating packages/c9watch/cli.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$CLI_TARGET"
sed -i "s|cliHashAarch64 = \"sha256-[^\"]*\"|cliHashAarch64 = \"$CLI_HASH_AARCH64\"|" "$CLI_TARGET"
sed -i "s|cliHashX86_64 = \"sha256-[^\"]*\"|cliHashX86_64 = \"$CLI_HASH_X86_64\"|" "$CLI_TARGET"

echo "  ✓ c9watch updated to $LATEST_VERSION"
