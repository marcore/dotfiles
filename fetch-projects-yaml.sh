#!/usr/bin/env bash
#
# fetch-projects-yaml.sh
#
# Run this MANUALLY on a NEW laptop, before restore-projects.sh, once the
# Bitwarden CLI is set up and unlocked. Pulls the curated projects inventory
# back out of Bitwarden (pushed there by export-projects-yaml.sh) and writes
# it to .chezmoidata/projects.yaml, overwriting the committed placeholder.
#
# Refuses to overwrite a projects.yaml that already has real content (i.e.
# isn't the empty placeholder) unless --force is given, so it won't clobber
# curation work in progress on a laptop that already has real data.
#
# After writing the real file, marks it git-skip-worktree so its
# content never shows up in `git status`/`git diff` and can't accidentally
# get committed to this public repo -- run
# `git update-index --no-skip-worktree .chezmoidata/projects.yaml` to undo.
#
# Usage:
#   ./fetch-projects-yaml.sh [--force] [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRET_NAME="dotfiles:projects.yaml"

FORCE=0
PROJECTS_YAML=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) PROJECTS_YAML="$arg" ;;
    esac
done
PROJECTS_YAML="${PROJECTS_YAML:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"

if [[ -f "$PROJECTS_YAML" && "$FORCE" -ne 1 ]]; then
    existing_root=$(yq '.root' "$PROJECTS_YAML" 2>/dev/null || echo "")
    if [[ -n "$existing_root" && "$existing_root" != "null" ]]; then
        echo "Error: $PROJECTS_YAML already has real content (root: $existing_root)." >&2
        echo "Re-run with --force to overwrite it." >&2
        exit 1
    fi
fi

if ! bw list items --search "$SECRET_NAME" \
    | jq -e --arg n "$SECRET_NAME" '[.[] | select(.name==$n)] | .[0]' >/dev/null; then
    echo "Error: Bitwarden item not found for $SECRET_NAME" >&2
    exit 1
fi

mkdir -p "$(dirname "$PROJECTS_YAML")"
bw list items --search "$SECRET_NAME" \
    | jq -r --arg n "$SECRET_NAME" '[.[] | select(.name==$n)] | .[0].notes' \
    | base64 -d > "$PROJECTS_YAML"

echo "Fetched Bitwarden item $SECRET_NAME -> $PROJECTS_YAML"

if git -C "$SCRIPT_DIR" ls-files --error-unmatch "$PROJECTS_YAML" >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" update-index --skip-worktree "$PROJECTS_YAML"
    echo "Marked $PROJECTS_YAML as git-skip-worktree"
fi
