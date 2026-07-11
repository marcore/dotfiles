#!/bin/bash
#
# export-bookmarks.sh
#
# Run this MANUALLY on the OLD laptop, from the root of your dotfiles repo,
# whenever you want to refresh the bookmarks snapshot that chezmoi will
# apply on the new laptop.
#
# Usage:
#   ./export-bookmarks.sh
#
# This does NOT touch chezmoi state directly - it just copies the current
# Chrome "Default" profile Bookmarks file into chrome/bookmarks.json in the
# repo. Review/commit as normal afterwards.

set -euo pipefail

CHROME_PROFILE_DIR="$HOME/Library/Application Support/Google/Chrome/Default"
SRC="$CHROME_PROFILE_DIR/Bookmarks"
DEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$DEST_DIR/.chrome-data/bookmarks.json"

if [ ! -f "$SRC" ]; then
  echo "Error: Bookmarks file not found at:"
  echo "  $SRC"
  echo "Is Chrome installed and has it been run at least once?"
  exit 1
fi

# Warn if Chrome is currently running - the file can be mid-write.
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  echo "Warning: Google Chrome is currently running."
  echo "Quit Chrome first to guarantee a consistent snapshot? (recommended)"
  read -r -p "Continue anyway? [y/N] " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted. Quit Chrome and re-run."; exit 1 ;;
  esac
fi

cp "$SRC" "$DEST"

# Sanity check: make sure it's valid JSON before we let it into the repo.
if command -v jq >/dev/null 2>&1; then
  if ! jq empty "$DEST" >/dev/null 2>&1; then
    echo "Error: copied file is not valid JSON. Removing $DEST."
    rm -f "$DEST"
    exit 1
  fi
  count=$(jq '[.. | objects | select(.type=="url")] | length' "$DEST")
  echo "OK: exported $count bookmarks to $DEST"
else
  echo "OK: copied to $DEST (install jq to get a bookmark count + validation)"
fi

echo "Next steps: review the diff, then 'git add .chrome-data/bookmarks.json && git commit'"
