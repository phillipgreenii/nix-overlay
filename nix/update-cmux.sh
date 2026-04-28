# shellcheck shell=bash
# Update cmux package to latest GitHub release
# Called from update-locks.sh before nix flake update
#
# Checks GitHub for latest release, downloads DMG to get hash,
# and updates version/hash in packages/cmux/default.nix if newer.

REPO_ROOT="${1:-.}"
TARGET="${REPO_ROOT}/packages/cmux/default.nix"

if [[ ! -f $TARGET ]]; then
  echo "Error: packages/cmux/default.nix not found at $TARGET" >&2
  exit 1
fi

echo "Checking for cmux updates..."

# Get current version from cmux/default.nix (line with 'version = "X.Y.Z";')
CURRENT_VERSION=$(grep 'version = ' "$TARGET" | head -1 | sed 's/.*version = "\([^"]*\)".*/\1/')

if [[ -z $CURRENT_VERSION ]]; then
  echo "  Error: Could not find current cmux version in $TARGET" >&2
  exit 1
fi

# Get latest release from GitHub API
echo "  Fetching latest release info..."
GH_HEADERS=()
if [[ -n ${GH_TOKEN:-} ]]; then
  GH_HEADERS+=(-H "Authorization: Bearer $GH_TOKEN")
fi
LATEST_TAG=$(curl -s "${GH_HEADERS[@]}" https://api.github.com/repos/manaflow-ai/cmux/releases/latest | jq -r '.tag_name')
LATEST_VERSION="${LATEST_TAG#v}" # Strip 'v' prefix

if [[ -z $LATEST_VERSION || $LATEST_VERSION == "null" ]]; then
  echo "  Error: Could not fetch latest release from GitHub" >&2
  exit 1
fi

# Compare versions
if [[ $CURRENT_VERSION == "$LATEST_VERSION" ]]; then
  echo "  cmux is up to date ($CURRENT_VERSION)"
  exit 0
fi

echo "  New cmux release detected: $CURRENT_VERSION -> $LATEST_VERSION"

# Construct URL for DMG
DMG_URL="https://github.com/manaflow-ai/cmux/releases/download/v${LATEST_VERSION}/cmux-macos.dmg"

# Get hash using nix-prefetch-url
echo "  Fetching DMG to get hash..."
LATEST_HASH=$(nix-prefetch-url "$DMG_URL" 2>/dev/null)

if [[ -z $LATEST_HASH ]]; then
  echo "  Error: Could not prefetch DMG from $DMG_URL" >&2
  exit 1
fi

# Convert to SRI hash format (sha256-...)
LATEST_HASH_SRI=$(nix hash convert --hash-algo sha256 --to sri "$LATEST_HASH" 2>/dev/null || echo "sha256-$LATEST_HASH")

echo "  Updating packages/cmux/default.nix..."

# Update version field
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$LATEST_VERSION\";/" "$TARGET"

# Update hash (find the hash line in the fetchurl section)
sed -i "s|hash = \"sha256-[^\"]*\";|hash = \"$LATEST_HASH_SRI\";|" "$TARGET"

echo "  ✓ cmux updated to $LATEST_VERSION"
