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
#      path already exists) -- repos marked `auth: https` (e.g. Adobe Cloud
#      Manager git) are cloned using username/password from the Bitwarden
#      login item repo-auth:<auth_secret>, where auth_secret is set
#      alongside `auth: https` in the repo's projects.yaml entry (created
#      by add_repo_auth_to_bw.sh; repos that share credentials just use the
#      same auth_secret value); SSH repos with an
#      `ssh_identity: <key-filename>` entry get that key loaded into the
#      ssh-agent (ssh-add -D && ssh-add ~/.ssh/<key-filename>, same as the
#      gitmre/gitmarcore dot_zshrc aliases) before cloning, skipped when it's
#      already the last-loaded identity; all other SSH repos clone as-is
#      against whatever identity is currently loaded
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
CURRENT_SSH_IDENTITY=""

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
    local repo_path="$1" folder_count="$2" k
    for ((k = 0; k < folder_count; k++)); do
        local folder_path
        folder_path=$(yq ".folders[$k].path" "$PROJECTS_YAML")
        [[ "$repo_path" == "$folder_path"/* ]] && return 0
    done
    return 1
}

# Restores a single Bitwarden secret item (stored chunked across multiple
# secure notes by export-project-secrets.sh / add_secret_to_bw.sh
# --chunked, since Bitwarden attachments require Premium) to dest_path, or
# records a failure in FAILED_ITEMS if the index item or any chunk is
# missing.
restore_secret() {
    local secret_name="$1" dest_path="$2"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: restore secret $secret_name -> $dest_path"
        return 0
    fi
    local items_json index_notes chunk_count payload_b64 i chunk_notes
    items_json=$(bw list items --search "$secret_name")
    index_notes=$(echo "$items_json" | jq -r --arg n "$secret_name" '[.[] | select(.name==$n)] | .[0].notes // empty')
    if [[ -z "$index_notes" ]]; then
        echo "WARN: Bitwarden item not found for $secret_name (expected at $dest_path)" >&2
        FAILED_ITEMS+=("$secret_name")
        return 0
    fi
    if [[ "$index_notes" != CHUNKED:* ]]; then
        echo "WARN: Bitwarden item $secret_name is not in the expected chunked format (expected at $dest_path)" >&2
        FAILED_ITEMS+=("$secret_name")
        return 0
    fi
    chunk_count="${index_notes#CHUNKED:}"

    payload_b64=""
    for ((i = 0; i < chunk_count; i++)); do
        chunk_notes=$(echo "$items_json" | jq -r --arg n "${secret_name}#${i}" '[.[] | select(.name==$n)] | .[0].notes // empty')
        if [[ -z "$chunk_notes" ]]; then
            echo "WARN: missing chunk $i for $secret_name (expected at $dest_path)" >&2
            FAILED_ITEMS+=("$secret_name")
            return 0
        fi
        payload_b64+="$chunk_notes"
    done

    mkdir -p "$(dirname "$dest_path")"
    printf '%s' "$payload_b64" | base64 -d > "$dest_path"
    chmod 600 "$dest_path"
    echo "Restored secret $secret_name -> $dest_path"
}

# Clones a repo whose projects.yaml entry has `auth: https`, fetching
# username/password from the Bitwarden login item repo-auth:<auth_secret>
# (created by add_repo_auth_to_bw.sh) and feeding the password to git via a
# short-lived GIT_ASKPASS script -- the password is never embedded in
# .git/config's remote URL or passed as a plain argv argument. auth_secret
# comes straight from the repo's projects.yaml entry, so sibling repos that
# share one set of credentials (e.g. all repos under one customer's Cloud
# Manager program) just set the same auth_secret value. Returns non-zero if
# the Bitwarden item is missing or the clone fails.
clone_with_https_auth() {
    local remote_url="$1" repo_path="$2" auth_secret="$3"
    local secret_name="repo-auth:${auth_secret}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: git clone (https, credentials from Bitwarden item $secret_name) $remote_url -> $repo_path"
        return 0
    fi

    local item username password askpass authed_url clone_status
    if ! item=$(bw list items --search "$secret_name" \
        | jq -e --arg n "$secret_name" '[.[] | select(.name==$n)] | .[0]'); then
        echo "WARN: Bitwarden login item not found for $secret_name (expected for $repo_path)" >&2
        return 1
    fi
    username=$(echo "$item" | jq -r '.login.username | @uri')
    password=$(echo "$item" | jq -r '.login.password')

    askpass=$(mktemp)
    printf '#!/bin/sh\necho "%s"\n' "$password" > "$askpass"
    chmod 700 "$askpass"
    authed_url="${remote_url/https:\/\//https://$username@}"

    clone_status=0
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git clone "$authed_url" "$repo_path" || clone_status=$?
    rm -f "$askpass"
    return "$clone_status"
}

# Loads ~/.ssh/<identity> into the ssh-agent (ssh-add -D && ssh-add), same
# as the gitmre/gitmarcore dot_zshrc aliases -- but only when it differs
# from the identity already loaded, so consecutive repos sharing an
# identity don't reset the agent (and potentially re-prompt for a
# passphrase) for no reason. Returns non-zero if ssh-add fails.
ensure_ssh_identity() {
    local identity="$1"
    [[ "$identity" == "$CURRENT_SSH_IDENTITY" ]] && return 0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: ssh-add -D && ssh-add ~/.ssh/$identity"
        CURRENT_SSH_IDENTITY="$identity"
        return 0
    fi

    if ! ssh-add -D >/dev/null 2>&1 || ! ssh-add "$HOME/.ssh/$identity" >/dev/null 2>&1; then
        echo "WARN: failed to load ssh identity $identity into ssh-agent" >&2
        return 1
    fi
    CURRENT_SSH_IDENTITY="$identity"
    echo "Switched ssh-agent identity to $identity"
}

# Finds the index into repos[] whose path equals $1. Echoes the index and
# returns 0 on success; returns 1 if no match is found.
find_repo_index_by_path() {
    local target="$1" count="$2" k
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
    local repo_path remote_url repo_rel auth auth_secret ssh_identity file_count j
    repo_path=$(yq ".repos[$idx].path" "$PROJECTS_YAML")
    remote_url=$(yq ".repos[$idx].remotes[0].url" "$PROJECTS_YAML")
    auth=$(yq ".repos[$idx].auth // \"\"" "$PROJECTS_YAML")
    auth_secret=$(yq ".repos[$idx].auth_secret // \"\"" "$PROJECTS_YAML")
    ssh_identity=$(yq ".repos[$idx].ssh_identity // \"\"" "$PROJECTS_YAML")
    repo_rel="${repo_path#"$projects_root"/}"

    if [[ -d "$repo_path" ]]; then
        echo "Skipping clone, already exists: $repo_path"
    else
        run mkdir -p "$(dirname "$repo_path")"
        local clone_status=0
        if [[ "$auth" == "https" ]]; then
            if [[ -z "$auth_secret" ]]; then
                echo "WARN: $repo_path has auth: https but no auth_secret set in $PROJECTS_YAML" >&2
                FAILED_ITEMS+=("$repo_path")
                return 0
            fi
            clone_with_https_auth "$remote_url" "$repo_path" "$auth_secret" || clone_status=$?
        elif [[ -n "$ssh_identity" ]] && ! ensure_ssh_identity "$ssh_identity"; then
            clone_status=1
        else
            run git clone "$remote_url" "$repo_path" || clone_status=$?
        fi
        if [[ "$clone_status" -ne 0 ]]; then
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
