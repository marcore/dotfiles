#!/usr/bin/env bash
#
# restore-projects.sh
#
# Run this MANUALLY on a NEW laptop, from the root of your dotfiles repo,
# once SSH keys and Bitwarden CLI are already set up (see
# .install-prerequisites.sh and private_dot_ssh/) and
# ./fetch-projects-yaml.sh has been run to pull the real
# .chezmoidata/projects.yaml down from Bitwarden.
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
    echo "Run ./fetch-projects-yaml.sh first to pull it down from Bitwarden." >&2
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
    chmod 600 "$dest_path"
    echo "Restored secret $secret_name -> $dest_path"
}

# Finds the index into repos[] whose path equals $1. Echoes the index and
# returns 0 on success; returns 1 if no match is found.
find_repo_index_by_path() {
    local target="$1" count="$2"
    for ((k = 0; k < count; k++)); do
        local p
        p=$(yq ".repos[$k].path" "$PROJECTS_YAML")
        if [[ "$p" == "$target" ]]; then
            echo "$k"
            return 0
        fi
    done
    return 1
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
        if ! run git clone "$remote_url" "$repo_path"; then
            echo "WARN: git clone failed for $repo_path (remote: $remote_url)" >&2
            FAILED_ITEMS+=("$repo_path")
            return 0
        fi
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

if [[ "$folder_count" -gt 0 && -z "$ONEDRIVE_DIR" ]]; then
    echo "Error: onedriveProjectsBackupDir is not set (chezmoi data) and \$ONEDRIVE_PROJECTS_BACKUP_DIR is not set" >&2
    exit 1
fi

echo "== Restoring top-level repos =="
for ((i = 0; i < repo_count; i++)); do
    repo_path=$(yq ".repos[$i].path" "$PROJECTS_YAML")
    if is_nested_repo "$repo_path" "$folder_count"; then
        continue
    fi
    restore_repo "$i"
done

echo "== Restoring folder roots =="
for ((i = 0; i < folder_count; i++)); do
    folder_path=$(yq ".folders[$i].path" "$PROJECTS_YAML")
    parent_dir="$(dirname "$folder_path")"
    archive_name="$(echo "${folder_path#"$projects_root"/}" | tr '/' '-').zip"
    archive_path="$ONEDRIVE_DIR/$archive_name"

    if [[ -d "$folder_path" ]]; then
        echo "Skipping unzip, already exists: $folder_path"
    elif [[ ! -f "$archive_path" ]]; then
        echo "WARN: archive not found for $folder_path (expected $archive_path)" >&2
        FAILED_ITEMS+=("$archive_path")
    else
        run mkdir -p "$parent_dir"
        if ! run unzip -q "$archive_path" -d "$parent_dir"; then
            echo "WARN: unzip failed for $folder_path (archive: $archive_path)" >&2
            FAILED_ITEMS+=("$archive_path")
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 || -d "$folder_path" ]]; then
        nested_count=$(yq ".folders[$i].nested_repos | length" "$PROJECTS_YAML")
        for ((j = 0; j < nested_count; j++)); do
            nested_rel=$(yq ".folders[$i].nested_repos[$j]" "$PROJECTS_YAML")
            nested_path="$folder_path/$nested_rel"
            idx=$(find_repo_index_by_path "$nested_path" "$repo_count") || {
                echo "WARN: no repos[] entry found for nested repo $nested_path" >&2
                FAILED_ITEMS+=("$nested_path")
                continue
            }
            restore_repo "$idx"
        done
    fi
done

if [[ "${#FAILED_ITEMS[@]}" -gt 0 ]]; then
    echo "== Summary: ${#FAILED_ITEMS[@]} item(s) failed to restore =="
    printf '  %s\n' "${FAILED_ITEMS[@]}"
fi
