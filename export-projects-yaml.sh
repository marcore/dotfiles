#!/usr/bin/env bash
#
# export-projects-yaml.sh
#
# Run this MANUALLY on the laptop that holds the curated
# .chezmoidata/projects.yaml, any time you re-curate it (add/remove repos or
# folders, prune ignored_files, etc.).
#
# Pushes the file's content into Bitwarden as a secure note via
# add_secret_to_bw.sh --update, under the fixed name
# "dotfiles:projects.yaml" -- --update means re-running this after
# re-curating updates the existing item's content instead of leaving it
# stale.
#
# projects.yaml itself is NOT committed to this repo (only a placeholder is,
# see .chezmoidata/projects.yaml's header): the real curated inventory names
# private/internal repos and org structure, so it's kept out of the public
# dotfiles repo and round-tripped through Bitwarden instead, via this script
# and fetch-projects-yaml.sh.
#
# Usage:
#   ./export-projects-yaml.sh [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_YAML="${1:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"
ADD_SECRET_SCRIPT="${ADD_SECRET_SCRIPT:-$SCRIPT_DIR/add_secret_to_bw.sh}"
SECRET_NAME="dotfiles:projects.yaml"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi

"$ADD_SECRET_SCRIPT" "$SECRET_NAME" "$PROJECTS_YAML" --update
echo "Exported $PROJECTS_YAML -> Bitwarden item $SECRET_NAME"
