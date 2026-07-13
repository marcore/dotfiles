#!/usr/bin/env bash
#
# add_repo_auth_to_bw.sh
#
# Run this MANUALLY whenever you need to store (or refresh) HTTPS
# username/password credentials for repos that can't use SSH -- e.g. Adobe
# Cloud Manager git (dot_gitconfig.tmpl sets `useHttpPath = true` for
# git.cloudmanager.adobe.com since credentials are per-repo-path in the URL,
# but in practice the same username/password work for every repo under a
# given customer's Cloud Manager program).
#
# Creates or updates a Bitwarden LOGIN item (not a secure note -- this is a
# real username/password pair) named:
#
#   repo-auth:<auth_secret>
#
# where <auth_secret> must match the auth_secret value set alongside
# `auth: https` in projects.yaml for each repo that should use these
# credentials. Repos that share credentials (e.g. all repos under one
# customer's Cloud Manager program) just set the same auth_secret value, so
# a common choice is the customer name, but any string works as long as it
# matches what's in projects.yaml.
#
# Prompts interactively for username and password (password input hidden)
# rather than taking them as arguments, so credentials never end up in
# shell history or process listings.
#
# Usage:
#   ./add_repo_auth_to_bw.sh <auth_secret>

set -euo pipefail

AUTH_SECRET="${1:?Usage: $0 <auth_secret>}"
SECRET_NAME="repo-auth:${AUTH_SECRET}"
FOLDER_ID="87355180-f451-42e2-b20e-b32500ac9ff2"

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
