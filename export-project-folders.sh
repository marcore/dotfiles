#!/usr/bin/env bash
#
# export-project-folders.sh
#
# Run this MANUALLY on the OLD laptop, from the root of your dotfiles repo,
# whenever you want to refresh the zip archives of your curated plain
# (non-git) project folders.
#
# Reads .chezmoidata/projects.yaml and, for each entry under `folders:`,
# zips that folder into the OneDrive backup dir, excluding any
# nested_repos (those are restored separately via git clone by
# restore-projects.sh).
#
# Usage:
#   ./export-project-folders.sh [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml
#   Backup dir comes from $ONEDRIVE_PROJECTS_BACKUP_DIR, falling back to
#   the onedriveProjectsBackupDir chezmoi data value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_YAML="${1:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"
ONEDRIVE_DIR="${ONEDRIVE_PROJECTS_BACKUP_DIR:-$(chezmoi data 2>/dev/null | jq -r '.onedriveProjectsBackupDir // empty')}"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi
if [[ -z "$ONEDRIVE_DIR" ]]; then
    echo "Error: onedriveProjectsBackupDir is not set (chezmoi data) and \$ONEDRIVE_PROJECTS_BACKUP_DIR is not set" >&2
    exit 1
fi
mkdir -p "$ONEDRIVE_DIR"

projects_root=$(yq '.root' "$PROJECTS_YAML")
folder_count=$(yq '.folders | length' "$PROJECTS_YAML")

for ((i = 0; i < folder_count; i++)); do
    folder_path=$(yq ".folders[$i].path" "$PROJECTS_YAML")
    folder_name="$(basename "$folder_path")"
    parent_dir="$(dirname "$folder_path")"
    archive_name="$(echo "${folder_path#"$projects_root"/}" | tr '/' '-').zip"
    archive_path="$ONEDRIVE_DIR/$archive_name"

    if [[ ! -d "$folder_path" ]]; then
        echo "WARN: folder not found, skipping: $folder_path" >&2
        continue
    fi

    exclude_args=()
    nested_count=$(yq ".folders[$i].nested_repos | length" "$PROJECTS_YAML")
    for ((j = 0; j < nested_count; j++)); do
        nested_rel=$(yq ".folders[$i].nested_repos[$j]" "$PROJECTS_YAML")
        exclude_args+=(-x "$folder_name/$nested_rel/*")
    done

    rm -f "$archive_path"
    (cd "$parent_dir" && zip -qr "$archive_path" "$folder_name" "${exclude_args[@]}")
    echo "Exported $folder_path -> $archive_path"
done
