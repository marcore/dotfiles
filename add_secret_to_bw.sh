#!/bin/bash
#
# Usage: add_secret_to_bw.sh SECRET_NAME SECRET_PATH [--update] [--chunked]
#
# By default, does nothing if a Bitwarden item named SECRET_NAME already
# exists (safe for stable secrets like SSH keys, which shouldn't change
# once created). Pass --update to instead overwrite the existing item's
# content with SECRET_PATH's current content -- for secrets that are
# expected to change over time (project .env files, etc.), re-run with
# --update whenever the local file changes.
#
# Pass --chunked to store SECRET_PATH's content across multiple Bitwarden
# secure-note items instead of a single item's `notes` field, for content
# that might exceed Bitwarden's 10000 *encrypted*-character cap on `notes`
# (in practice only a few KB of raw content -- project secret files, the
# curated projects.yaml, etc. easily exceed it). Bitwarden attachments
# would be the obvious alternative, but they require a Premium
# subscription, so this uses only standard secure notes.
#
# --chunked layout:
#   SECRET_NAME            -- "index" item, notes = "CHUNKED:<count>"
#   SECRET_NAME#0 .. #(count-1) -- chunk items, each holding one slice of
#     the base64-encoded content in its notes field (each comfortably
#     under the 10000-char cap)
# --chunked always replaces existing content (create-or-update in one
# mode; no separate --update needed) and deletes any now-orphaned trailing
# chunk items if the new content needs fewer chunks than before.

set -euo pipefail

SECRET_NAME=$1
SECRET_PATH=$2
UPDATE=0
CHUNKED=0
for arg in "${@:3}"; do
    case "$arg" in
        --update) UPDATE=1 ;;
        --chunked) CHUNKED=1 ;;
    esac
done
FOLDER_ID="38987615-b6e6-4747-8495-b482008750a4"
CHUNK_SIZE=5000

secure_note_json() {
    local name="$1" notes="$2"
    jq -n --arg name "$name" --arg folder "$FOLDER_ID" --arg notes "$notes" \
        '{organizationId: null, folderId: $folder, type: 2, name: $name, notes: $notes, favorite: false, fields: [], login: null, secureNote: {type: 0}, card: null, identity: null}'
}

if [[ "$CHUNKED" -eq 1 ]]; then
    payload_b64="$(base64 -w 0 -i "${SECRET_PATH}")"
    chunk_count=$(( (${#payload_b64} + CHUNK_SIZE - 1) / CHUNK_SIZE ))
    [[ "$chunk_count" -eq 0 ]] && chunk_count=1

    existing_items_json=$(bw list items --search "${SECRET_NAME}")
    index_id=$(echo "$existing_items_json" | jq -r --arg n "${SECRET_NAME}" '[.[] | select(.name==$n)] | .[0].id // empty')

    if [[ -z "$index_id" ]]; then
        echo "Creating Bitwarden item ${SECRET_NAME} (chunked, ${chunk_count} chunk(s))"
        index_id=$(secure_note_json "${SECRET_NAME}" "CHUNKED:${chunk_count}" | bw encode | bw create item | jq -r '.id')
    else
        echo "Updating Bitwarden item ${SECRET_NAME} (chunked, ${chunk_count} chunk(s))"
        bw get item "$index_id" | jq --arg notes "CHUNKED:${chunk_count}" '.notes = $notes' | bw encode | bw edit item "$index_id" >/dev/null
    fi

    for ((i = 0; i < chunk_count; i++)); do
        chunk_name="${SECRET_NAME}#${i}"
        chunk_content="${payload_b64:$((i * CHUNK_SIZE)):$CHUNK_SIZE}"
        chunk_id=$(echo "$existing_items_json" | jq -r --arg n "$chunk_name" '[.[] | select(.name==$n)] | .[0].id // empty')
        if [[ -z "$chunk_id" ]]; then
            secure_note_json "$chunk_name" "$chunk_content" | bw encode | bw create item >/dev/null
        else
            bw get item "$chunk_id" | jq --arg notes "$chunk_content" '.notes = $notes' | bw encode | bw edit item "$chunk_id" >/dev/null
        fi
    done

    # Remove any trailing chunk items left over from a previous, larger version.
    orphan_ids=$(echo "$existing_items_json" | jq -r --arg prefix "${SECRET_NAME}#" --argjson keep "$chunk_count" \
        '.[] | select(.name | startswith($prefix)) | select((.name[($prefix | length):] | tonumber) >= $keep) | .id')
    for orphan_id in $orphan_ids; do
        bw delete item "$orphan_id" >/dev/null
    done

    bw sync # optional
    echo "Stored ${SECRET_PATH} -> Bitwarden item ${SECRET_NAME} (${chunk_count} chunk(s))"
    exit 0
fi

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
