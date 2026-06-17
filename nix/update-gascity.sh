#!/usr/bin/env bash
# shellcheck shell=bash
# Update gascity package to latest GitHub release.
# Called from update-locks.sh before nix flake update.
#
# Downloads both supported-platform artifacts to get hashes, and updates
# version and hashes in packages/gascity/default.nix if a newer release
# is available. Supported platforms: aarch64-darwin, x86_64-linux.

set -euo pipefail

REPO_ROOT="${1:-.}"
TARGET="${REPO_ROOT}/packages/gascity/default.nix"

if [[ ! -f $TARGET ]]; then
  echo "Error: packages/gascity/default.nix not found at $TARGET" >&2
  exit 1
fi

echo "Checking for gascity updates..."

CURRENT_VERSION=$(grep 'version = ' "$TARGET" | head -1 | sed 's/.*version = "\([^"]*\)".*/\1/')

if [[ -z $CURRENT_VERSION ]]; then
  echo "  Error: Could not find current gascity version in $TARGET" >&2
  exit 1
fi

echo "  Fetching latest release info..."
GH_HEADERS=()
if [[ -n ${GH_TOKEN:-} ]]; then
  GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")
fi
LATEST_TAG=$(curl -s "${GH_HEADERS[@]}" https://api.github.com/repos/gastownhall/gascity/releases/latest | jq -r '.tag_name')
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z $LATEST_VERSION || $LATEST_VERSION == "null" ]]; then
  echo "  Error: Could not fetch latest release from GitHub" >&2
  exit 1
fi

if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
  echo "  gascity is up to date ($CURRENT_VERSION)"
  exit 0
fi

echo "  New gascity release detected: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Fetching artifact hashes..."

DARWIN_ARM64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_darwin_arm64.tar.gz"
LINUX_AMD64_URL="https://github.com/gastownhall/gascity/releases/download/v${LATEST_VERSION}/gascity_${LATEST_VERSION}_linux_amd64.tar.gz"

RAW_DARWIN_ARM64=$(nix-prefetch-url "$DARWIN_ARM64_URL" 2>/dev/null)
if [[ -z $RAW_DARWIN_ARM64 ]]; then
  echo "  Error: Could not prefetch $DARWIN_ARM64_URL" >&2
  exit 1
fi
RAW_LINUX_AMD64=$(nix-prefetch-url "$LINUX_AMD64_URL" 2>/dev/null)
if [[ -z $RAW_LINUX_AMD64 ]]; then
  echo "  Error: Could not prefetch $LINUX_AMD64_URL" >&2
  exit 1
fi

HASH_DARWIN_ARM64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_DARWIN_ARM64")
if [[ -z $HASH_DARWIN_ARM64 ]]; then
  echo "  Error: nix hash convert failed for $RAW_DARWIN_ARM64" >&2
  exit 1
fi
HASH_LINUX_AMD64=$(nix hash convert --hash-algo sha256 --to sri "$RAW_LINUX_AMD64")
if [[ -z $HASH_LINUX_AMD64 ]]; then
  echo "  Error: nix hash convert failed for $RAW_LINUX_AMD64" >&2
  exit 1
fi

echo "  Updating packages/gascity/default.nix..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$TARGET"
# Each platform's hash is rewritten via a sed range anchored on its unique
# `artifact = "..."` line up to the next `};`. This works regardless of
# whether nixfmt has kept the attrset entry on one line or split it across
# multiple lines.
sed -i "/artifact = \"darwin_arm64\";/,/};/ s|hash = \"[^\"]*\";|hash = \"$HASH_DARWIN_ARM64\";|" "$TARGET"
sed -i "/artifact = \"linux_amd64\";/,/};/ s|hash = \"[^\"]*\";|hash = \"$HASH_LINUX_AMD64\";|" "$TARGET"

echo "  ✓ gascity updated to $LATEST_VERSION"
