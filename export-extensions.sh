#!/bin/bash
#
# export-extensions.sh
#
# Run this MANUALLY on the OLD laptop, from the root of your dotfiles repo,
# to snapshot the currently installed Chrome extensions (Default profile)
# into chrome/extensions.json.
#
# Requires: jq (brew install jq)
#
# Notes:
#   - This reads "Secure Preferences", which lists every extension Chrome
#     knows about, including a handful of Google-internal component
#     extensions (things like the PDF viewer, Cryptotoken, etc.) that get
#     installed automatically anyway and don't need to be force-installed.
#     Those are filtered out below based on their "location" field, but
#     review the output once and prune anything you don't actually want
#     force-installed on the new machine.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

CHROME_PROFILE_DIR="$HOME/Library/Application Support/Google/Chrome/Default"
SRC="$CHROME_PROFILE_DIR/Secure Preferences"
DEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$DEST_DIR/.chezmoidata/chrome/extensions.json"

if [ ! -f "$SRC" ]; then
  echo "Error: Secure Preferences file not found at:"
  echo "  $SRC"
  exit 1
fi

# location values seen in Chrome's extension prefs:
#   1 = INTERNAL (installed from Web Store by the user)  -> keep
#   2 = EXTERNAL_PREF                                     -> keep (side-loaded)
#   4 = UNPACKED (dev/unpacked, machine-specific)          -> skip
#   5 = COMPONENT (built into Chrome, e.g. PDF viewer)     -> skip
#   10 = EXTERNAL_PREF_DOWNLOAD                            -> keep
#
# We keep extensions with a webstore-style manifest and drop components.
jq '
  [
    .extensions.settings // {}
    | to_entries[]
    | select(.value.manifest != null)
    | select(.value.location != 5)
    | select(.value.state == 1)
    | {
        id: .key,
        name: (.value.manifest.name // "unknown"),
        version: (.value.manifest.version // "unknown"),
        webstore_url: ("https://chrome.google.com/webstore/detail/" + .key)
      }
  ]
  | sort_by(.name)
' "$SRC" > "$DEST"

count=$(jq 'length' "$DEST")
echo "OK: exported $count extensions to $DEST"
echo ""
echo "Review this list before committing - some entries may have generic"
echo "names pulled from localized manifests (e.g. '__MSG_extName__')."
echo "Next steps: review the diff, then 'git add chrome/extensions.json && git commit'"
