#!/usr/bin/env bash
# Update beads-web package to latest GitHub release.
# Called from update-locks.sh before nix flake update.
#
# Checks GitHub for latest release, downloads all three artifacts to get
# hashes, and updates version and hashes in packages/beads-web/default.nix
# if a newer release is available.

REPO_ROOT="${1:-.}"
TARGET="${REPO_ROOT}/packages/beads-web/default.nix"

if [[ ! -f $TARGET ]]; then
  echo "Error: packages/beads-web/default.nix not found at $TARGET" >&2
  exit 1
fi

echo "Checking for beads-web updates..."

CURRENT_VERSION=$(grep 'version = ' "$TARGET" | head -1 | sed 's/.*version = "\([^"]*\)".*/\1/')

if [[ -z $CURRENT_VERSION ]]; then
  echo "  Error: Could not find current beads-web version in $TARGET" >&2
  exit 1
fi

echo "  Fetching latest release info..."
GH_HEADERS=()
if [[ -n ${GH_TOKEN:-} ]]; then
  GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")
fi
LATEST_TAG=$(curl -s "${GH_HEADERS[@]}" https://api.github.com/repos/weselow/beads-web/releases/latest | jq -r '.tag_name')
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z $LATEST_VERSION || $LATEST_VERSION == "null" ]]; then
  echo "  Error: Could not fetch latest release from GitHub" >&2
  exit 1
fi

if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
  echo "  beads-web is up to date ($CURRENT_VERSION)"
  exit 0
fi

echo "  New beads-web release detected: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Fetching artifact hashes (downloading ~10 MB per artifact)..."

DARWIN_ARM64_URL="https://github.com/weselow/beads-web/releases/download/v${LATEST_VERSION}/beads-web-darwin-arm64"
DARWIN_X64_URL="https://github.com/weselow/beads-web/releases/download/v${LATEST_VERSION}/beads-web-darwin-x64"
LINUX_X64_URL="https://github.com/weselow/beads-web/releases/download/v${LATEST_VERSION}/beads-web-linux-x64"

RAW_DARWIN_ARM64=$(nix-prefetch-url "$DARWIN_ARM64_URL" 2>/dev/null)
[[ -z $RAW_DARWIN_ARM64 ]] && {
  echo "  Error: Could not prefetch $DARWIN_ARM64_URL" >&2
  exit 1
}
RAW_DARWIN_X64=$(nix-prefetch-url "$DARWIN_X64_URL" 2>/dev/null)
[[ -z $RAW_DARWIN_X64 ]] && {
  echo "  Error: Could not prefetch $DARWIN_X64_URL" >&2
  exit 1
}
RAW_LINUX_X64=$(nix-prefetch-url "$LINUX_X64_URL" 2>/dev/null)
[[ -z $RAW_LINUX_X64 ]] && {
  echo "  Error: Could not prefetch $LINUX_X64_URL" >&2
  exit 1
}

HASH_DARWIN_ARM64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_ARM64" 2>/dev/null || echo "sha256-$RAW_DARWIN_ARM64")
HASH_DARWIN_X64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_X64" 2>/dev/null || echo "sha256-$RAW_DARWIN_X64")
HASH_LINUX_X64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_LINUX_X64" 2>/dev/null || echo "sha256-$RAW_LINUX_X64")

echo "  Updating packages/beads-web/default.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$TARGET"
sed -i "s|darwin-arm64 = \"[^\"]*\";|darwin-arm64 = \"$HASH_DARWIN_ARM64\";|" "$TARGET"
sed -i "s|darwin-x64 = \"[^\"]*\";|darwin-x64 = \"$HASH_DARWIN_X64\";|" "$TARGET"
sed -i "s|linux-x64 = \"[^\"]*\";|linux-x64 = \"$HASH_LINUX_X64\";|" "$TARGET"

echo "  ✓ beads-web updated to $LATEST_VERSION"
