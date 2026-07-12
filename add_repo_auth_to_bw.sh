#!/usr/bin/env bash
#
# add_repo_auth_to_bw.sh
#
# Run this MANUALLY whenever you need to store (or refresh) HTTPS
# username/password credentials for a repo that can't use SSH -- e.g. Adobe
# Cloud Manager git, which issues a distinct access token per repo via its
# UI (dot_gitconfig.tmpl's `useHttpPath = true` for
# git.cloudmanager.adobe.com reflects this: credentials are per-repo-path,
# not shared).
#
# Creates or updates a Bitwarden LOGIN item (not a secure note -- this is a
# real username/password pair) named:
#
#   repo-auth:<repo-rel-path>
#
# where <repo-rel-path> is the repo's path relative to projects_root, same
# convention as proj-secret:<repo-rel-path>:<file> items. restore-projects.sh
# looks this item up for any repo whose projects.yaml entry has `auth:
# https`.
#
# Prompts interactively for username and password (password input hidden)
# rather than taking them as arguments, so credentials never end up in
# shell history or process listings.
#
# Usage:
#   ./add_repo_auth_to_bw.sh <repo-rel-path>

set -euo pipefail

REPO_REL="${1:?Usage: $0 <repo-rel-path>}"
SECRET_NAME="repo-auth:${REPO_REL}"
FOLDER_ID="38987615-b6e6-4747-8495-b482008750a4"

read -rp "Username for $SECRET_NAME: " username
read -rsp "Password/token for $SECRET_NAME: " password
echo

existing_id=$(bw list items --search "$SECRET_NAME" \
    | jq -r --arg n "$SECRET_NAME" '[.[] | select(.name==$n)] | .[0].id // empty')

if [[ -n "$existing_id" ]]; then
    echo "Updating existing Bitwarden login item $SECRET_NAME"
    bw get item "$existing_id" \
        | jq --arg u "$username" --arg p "$password" '.login.username = $u | .login.password = $p' \
        | bw encode \
        | bw edit item "$existing_id" >/dev/null
else
    echo "Creating Bitwarden login item $SECRET_NAME"
    jq -n --arg name "$SECRET_NAME" --arg folder "$FOLDER_ID" --arg u "$username" --arg p "$password" \
        '{organizationId: null, folderId: $folder, type: 1, name: $name, notes: null, favorite: false, fields: [], login: {username: $u, password: $p}, secureNote: null, card: null, identity: null}' \
        | bw encode | bw create item >/dev/null
fi

bw sync
echo "Stored credentials for $SECRET_NAME"
