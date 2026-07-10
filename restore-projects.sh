#!/usr/bin/env bash
#
# restore-projects.sh
#
# Run this MANUALLY on a NEW laptop, from the root of your dotfiles repo,
# once SSH keys and Bitwarden CLI are already set up (see
# .install-prerequisites.sh and private_dot_ssh/).
#
# Reads .chezmoidata/projects.yaml and:
#   1. git clones each top-level repo to its original path (skipped if the
#      path already exists)
#   2. restores each repo's gitignored "secret" files from Bitwarden
#      (items created by export-project-secrets.sh)
#   3. unzips each plain folder root from the OneDrive backup dir
#      (archives created by export-project-folders.sh)
#   4. git clones any nested repos back into place inside their folder root
#
# Usage:
#   ./restore-projects.sh [--dry-run] [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml
#   --dry-run prints planned actions without executing them
#   Backup dir comes from $ONEDRIVE_PROJECTS_BACKUP_DIR, falling back to
#   the onedriveProjectsBackupDir chezmoi data value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DRY_RUN=0
PROJECTS_YAML=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) PROJECTS_YAML="$arg" ;;
    esac
done
PROJECTS_YAML="${PROJECTS_YAML:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi

ONEDRIVE_DIR="${ONEDRIVE_PROJECTS_BACKUP_DIR:-$(chezmoi data 2>/dev/null | jq -r '.onedriveProjectsBackupDir // empty')}"

FAILED_ITEMS=()

# Runs $* normally, or just echoes it under --dry-run.
run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: $*"
    else
        "$@"
    fi
}

# True (exit 0) if $1 is a path inside any folders[].path in PROJECTS_YAML.
is_nested_repo() {
    local repo_path="$1" folder_count="$2"
    for ((k = 0; k < folder_count; k++)); do
        local folder_path
        folder_path=$(yq ".folders[$k].path" "$PROJECTS_YAML")
        [[ "$repo_path" == "$folder_path"/* ]] && return 0
    done
    return 1
}

# Restores a single Bitwarden secret item to dest_path, or records a
# failure in FAILED_ITEMS if the item doesn't exist.
restore_secret() {
    local secret_name="$1" dest_path="$2"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: restore secret $secret_name -> $dest_path"
        return 0
    fi
    if ! bw list items --search "$secret_name" \
        | jq -e --arg n "$secret_name" '[.[] | select(.name==$n)] | .[0]' >/dev/null; then
        echo "WARN: Bitwarden item not found for $secret_name (expected at $dest_path)" >&2
        FAILED_ITEMS+=("$secret_name")
        return 0
    fi
    mkdir -p "$(dirname "$dest_path")"
    bw list items --search "$secret_name" \
        | jq -r --arg n "$secret_name" '[.[] | select(.name==$n)] | .[0].notes' \
        | base64 -d > "$dest_path"
    echo "Restored secret $secret_name -> $dest_path"
}

# Clones repos[idx] if its path doesn't exist yet, then restores its
# gitignored secret files from Bitwarden.
restore_repo() {
    local idx="$1"
    local repo_path remote_url repo_rel file_count
    repo_path=$(yq ".repos[$idx].path" "$PROJECTS_YAML")
    remote_url=$(yq ".repos[$idx].remotes[0].url" "$PROJECTS_YAML")
    repo_rel="${repo_path#"$projects_root"/}"

    if [[ -d "$repo_path" ]]; then
        echo "Skipping clone, already exists: $repo_path"
    else
        run mkdir -p "$(dirname "$repo_path")"
        run git clone "$remote_url" "$repo_path"
    fi

    file_count=$(yq ".repos[$idx].ignored_files | length" "$PROJECTS_YAML")
    for ((j = 0; j < file_count; j++)); do
        local file_rel secret_name
        file_rel=$(yq ".repos[$idx].ignored_files[$j]" "$PROJECTS_YAML")
        secret_name="proj-secret:${repo_rel}:${file_rel}"
        restore_secret "$secret_name" "$repo_path/$file_rel"
    done
}

projects_root=$(yq '.root' "$PROJECTS_YAML")
repo_count=$(yq '.repos | length' "$PROJECTS_YAML")
folder_count=$(yq '.folders | length' "$PROJECTS_YAML")

echo "== Restoring top-level repos =="
for ((i = 0; i < repo_count; i++)); do
    repo_path=$(yq ".repos[$i].path" "$PROJECTS_YAML")
    if is_nested_repo "$repo_path" "$folder_count"; then
        continue
    fi
    restore_repo "$i"
done

if [[ "${#FAILED_ITEMS[@]}" -gt 0 ]]; then
    echo "== Summary: ${#FAILED_ITEMS[@]} item(s) failed to restore =="
    printf '  %s\n' "${FAILED_ITEMS[@]}"
fi
