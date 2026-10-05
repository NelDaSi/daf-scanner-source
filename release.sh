#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="N3ld4s1.DAF-Scanner"
REPO="NelDaSi/daf-scanner-source"
MIN_OS_VERSION="17.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_JSON="$SCRIPT_DIR/apps.json"

usage() {
  echo "Usage: $0 [--dry-run] <path to exported .ipa> <release notes text>" >&2
  exit 1
}

DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

[[ ${#POSITIONAL[@]} -eq 2 ]] || usage
IPA_INPUT_PATH="${POSITIONAL[0]}"
NOTES="${POSITIONAL[1]}"

# --- Step 1: prerequisites ---------------------------------------------

missing=()
for cmd in git python3 plutil shasum unzip; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: missing required tool(s): ${missing[*]}" >&2
  exit 1
fi

# gh is only needed for a real release (step 7), not for --dry-run (steps 1-4).
if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: GitHub CLI (gh) is not installed.

Fix:
  brew install gh
  gh auth login

Then re-run this script.
EOF
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Error: gh is installed but not authenticated.

Fix:
  gh auth login

Then re-run this script.
EOF
    exit 1
  fi
fi

if [[ ! -f "$IPA_INPUT_PATH" ]]; then
  echo "Error: IPA not found at: $IPA_INPUT_PATH" >&2
  exit 1
fi
IPA_PATH="$(cd "$(dirname "$IPA_INPUT_PATH")" && pwd)/$(basename "$IPA_INPUT_PATH")"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- Step 2: read version/build/bundle id from the IPA -----------------

EXTRACT_DIR="$WORKDIR/extracted"
mkdir -p "$EXTRACT_DIR"
unzip -q "$IPA_PATH" -d "$EXTRACT_DIR"

APP_DIR="$(find "$EXTRACT_DIR/Payload" -maxdepth 1 -iname '*.app' | head -n1)"
if [[ -z "$APP_DIR" ]]; then
  echo "Error: could not find a .app bundle inside $IPA_PATH (Payload/*.app)" >&2
  exit 1
fi

INFO_PLIST="$APP_DIR/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
FOUND_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"

if [[ "$FOUND_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Error: bundle ID mismatch. Expected $BUNDLE_ID, found $FOUND_BUNDLE_ID" >&2
  exit 1
fi

# --- Step 3: version/tag collision checks -------------------------------

VERSION_EXISTS="$(python3 - "$APPS_JSON" "$VERSION" <<'PYEOF'
import json, sys
apps_json_path, version = sys.argv[1], sys.argv[2]
with open(apps_json_path) as f:
    data = json.load(f)
versions = data["apps"][0]["versions"]
print("yes" if any(v.get("version") == version for v in versions) else "no")
PYEOF
)"
if [[ "$VERSION_EXISTS" == "yes" ]]; then
  echo "Error: version $VERSION already exists in apps.json" >&2
  exit 1
fi

if git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "Error: git tag v$VERSION already exists locally" >&2
  exit 1
fi

set +e
git -C "$SCRIPT_DIR" ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1
REMOTE_TAG_RC=$?
set -e
if [[ "$REMOTE_TAG_RC" -eq 0 ]]; then
  echo "Error: git tag v$VERSION already exists on origin" >&2
  exit 1
elif [[ "$REMOTE_TAG_RC" -ne 2 ]]; then
  echo "Warning: could not check origin for existing tags (network issue?); continuing with local check only" >&2
fi

# --- Step 4: size + sha256 ----------------------------------------------

SIZE="$(stat -f%z "$IPA_PATH")"
SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
DATE="$(date +%Y-%m-%d)"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/DAF-Scanner.ipa"

# Helper used for both printing the dry-run entry and applying it for real.
APPLY_HELPER="$WORKDIR/apply_entry.py"
cat > "$APPLY_HELPER" <<'PYEOF'
import json, sys

apps_json_path, mode, version, build, date, notes, download_url, size, sha256, min_os = sys.argv[1:11]

entry = {
    "version": version,
    "buildVersion": build,
    "date": date,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": int(size),
    "sha256": sha256,
    "minOSVersion": min_os,
}

if mode == "print":
    print(json.dumps(entry, indent=2, ensure_ascii=False))
    sys.exit(0)

with open(apps_json_path) as f:
    data = json.load(f)
data["apps"][0]["versions"].insert(0, entry)
with open(apps_json_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY RUN - no changes made."
  echo
  echo "Version:  $VERSION"
  echo "Build:    $BUILD"
  echo "Size:     $SIZE bytes"
  echo "SHA256:   $SHA256"
  echo
  echo "New apps.json entry:"
  python3 "$APPLY_HELPER" "$APPS_JSON" print "$VERSION" "$BUILD" "$DATE" "$NOTES" "$DOWNLOAD_URL" "$SIZE" "$SHA256" "$MIN_OS_VERSION"
  exit 0
fi

# --- Step 5: copy IPA to a temp file named DAF-Scanner.ipa --------------

RELEASE_IPA="$WORKDIR/DAF-Scanner.ipa"
cp "$IPA_PATH" "$RELEASE_IPA"

# --- Step 7 (release first, then commit) --------------------------------

echo "Creating GitHub release v$VERSION..."
gh release create "v$VERSION" "$RELEASE_IPA" \
  --repo "$REPO" \
  --title "DAF Scanner $VERSION" \
  --notes "$NOTES"

# --- Step 6: update apps.json now that the asset exists ------------------

echo "Updating apps.json..."
python3 "$APPLY_HELPER" "$APPS_JSON" apply "$VERSION" "$BUILD" "$DATE" "$NOTES" "$DOWNLOAD_URL" "$SIZE" "$SHA256" "$MIN_OS_VERSION"

git -C "$SCRIPT_DIR" add apps.json
git -C "$SCRIPT_DIR" commit -m "Release $VERSION ($BUILD)"
git -C "$SCRIPT_DIR" push

# --- Step 8: summary -------------------------------------------------------

echo
echo "Release complete."
echo "Version:     $VERSION"
echo "Build:       $BUILD"
echo "Size:        $SIZE bytes"
echo "Source URL:  https://neldasi.github.io/daf-scanner-source/apps.json"
