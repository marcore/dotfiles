#!/usr/bin/env bash
#
# export-project-secrets.sh
#
# Run this MANUALLY on the OLD laptop, from the root of your dotfiles repo,
# whenever you refresh the set of gitignored "secret" files (.env, credential
# files, ...) that need to survive a laptop migration.
#
# Reads .chezmoidata/projects.yaml and, for every repo's ignored_files entry,
# pushes the file's content into Bitwarden as a secure note via
# add_secret_to_bw.sh --update, using the naming convention:
#
#   proj-secret:<repo-path-relative-to-projects-root>:<file-relative-path>
#
# Passing --update means re-running this after a project secret's content
# changes (a rotated token in .env, etc.) refreshes the existing Bitwarden
# item instead of leaving it stale -- unlike add_secret_to_bw.sh's default
# create-only behavior, which is meant for stable secrets like SSH keys.
#
# Usage:
#   ./export-project-secrets.sh [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_YAML="${1:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"
ADD_SECRET_SCRIPT="${ADD_SECRET_SCRIPT:-$SCRIPT_DIR/add_secret_to_bw.sh}"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi

projects_root=$(yq '.root' "$PROJECTS_YAML")
repo_count=$(yq '.repos | length' "$PROJECTS_YAML")

for ((i = 0; i < repo_count; i++)); do
    repo_path=$(yq ".repos[$i].path" "$PROJECTS_YAML")
    repo_rel="${repo_path#"$projects_root"/}"

    file_count=$(yq ".repos[$i].ignored_files | length" "$PROJECTS_YAML")
    for ((j = 0; j < file_count; j++)); do
        file_rel=$(yq ".repos[$i].ignored_files[$j]" "$PROJECTS_YAML")
        secret_path="$repo_path/$file_rel"
        secret_name="proj-secret:${repo_rel}:${file_rel}"

        if [[ ! -f "$secret_path" ]]; then
            echo "Skipping $secret_name: $secret_path not found locally"
            continue
        fi

        echo "Exporting $secret_name"
        "$ADD_SECRET_SCRIPT" "$secret_name" "$secret_path" --update
    done
done
