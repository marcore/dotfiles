#!/bin/bash
#
# Usage: add_secret_to_bw.sh SECRET_NAME SECRET_PATH [--update]
#
# By default, does nothing if a Bitwarden item named SECRET_NAME already
# exists (safe for stable secrets like SSH keys, which shouldn't change
# once created). Pass --update to instead overwrite the existing item's
# content with SECRET_PATH's current content -- for secrets that are
# expected to change over time (project .env files, etc.), re-run with
# --update whenever the local file changes.

set -euo pipefail

SECRET_NAME=$1
SECRET_PATH=$2
UPDATE=0
[[ "${3:-}" == "--update" ]] && UPDATE=1
FOLDER_ID="38987615-b6e6-4747-8495-b482008750a4"

echo "Check if already exists in bitwarden"
existing_id=$(bw list items --search "${SECRET_NAME}" | jq -r --arg n "${SECRET_NAME}" '[.[] | select(.name==$n)] | .[0].id // empty')

if [[ -n "$existing_id" ]]; then
    if [[ "$UPDATE" -ne 1 ]]; then
        echo "Secret already exists in bitwarden, skipping creation (pass --update to overwrite its content)"
        exit 0
    fi
    echo "Secret already exists in bitwarden, updating its content"
    bw get item "$existing_id" \
        | jq --arg notes "$(base64 -w 0 -i "${SECRET_PATH}")" '.notes = $notes' \
        | bw encode \
        | bw edit item "$existing_id" >/dev/null
else
    # store the secret content as an item in bitwarden
    echo "{\"organizationId\":null,\"folderId\":\"${FOLDER_ID}\",\"type\":2,\"name\":\"${SECRET_NAME}\",\"notes\":\"$(base64 -w 0 -i ${SECRET_PATH})\",\"favorite\":false,\"fields\":[],\"login\":null,\"secureNote\":{\"type\":0},\"card\":null,\"identity\":null}" | bw encode | bw create item
fi
bw sync # optional
# retrieve  the secret
# assuming a single search result
bw list items --search "${SECRET_NAME}" | jq "[.[]? | select (.name==\"${SECRET_NAME}\")]"  | jq -r '.[0].notes' | base64 -d > ${SECRET_PATH}
# in case you're using chezmoi here's a template that will retrieve that secret automatically
#$cat $(chezmoi source-path ${SECRET_PATH})
#{{ (bitwarden "item" "${SECRET_NAME}").notes | b64dec }}
chezmoi execute-template "`cat $(chezmoi source-path ${SECRET_PATH})`"