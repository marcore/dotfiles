#!/usr/bin/env bash
#
# export-projects-yaml.sh
#
# Run this MANUALLY on the laptop that holds the curated
# .chezmoidata/projects.yaml, any time you re-curate it (add/remove repos or
# folders, prune ignored_files, etc.).
#
# Pushes the file's content into Bitwarden as a secure note (base64-encoded
# in the notes field, same convention as proj-secret items), under the fixed
# name "dotfiles:projects.yaml". Unlike add_secret_to_bw.sh -- which only
# creates an item once and skips if it already exists -- this script updates
# the existing item's content, since projects.yaml is expected to change
# over time.
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
SECRET_NAME="dotfiles:projects.yaml"
FOLDER_ID="38987615-b6e6-4747-8495-b482008750a4"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi

encoded_notes="$(base64 -w 0 -i "$PROJECTS_YAML")"

existing_id=$(bw list items --search "$SECRET_NAME" \
    | jq -r --arg n "$SECRET_NAME" '[.[] | select(.name==$n)] | .[0].id // empty')

if [[ -n "$existing_id" ]]; then
    echo "Updating existing Bitwarden item $SECRET_NAME"
    bw get item "$existing_id" \
        | jq --arg notes "$encoded_notes" '.notes = $notes' \
        | bw encode \
        | bw edit item "$existing_id" >/dev/null
else
    echo "Creating Bitwarden item $SECRET_NAME"
    echo "{\"organizationId\":null,\"folderId\":\"${FOLDER_ID}\",\"type\":2,\"name\":\"${SECRET_NAME}\",\"notes\":\"${encoded_notes}\",\"favorite\":false,\"fields\":[],\"login\":null,\"secureNote\":{\"type\":0},\"card\":null,\"identity\":null}" \
        | bw encode | bw create item >/dev/null
fi

bw sync
echo "Exported $PROJECTS_YAML -> Bitwarden item $SECRET_NAME"
