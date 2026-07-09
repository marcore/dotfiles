#!/bin/bash
set -euo pipefail

SECRET_NAME=$1
SECRET_PATH=$2
FOLDER_ID="38987615-b6e6-4747-8495-b482008750a4"

echo "Check if already exists in bitwarden"
# check if the secret already exists in bitwarden
if bw list items --search "${SECRET_NAME}" | jq "[.[]? | select (.name==\"${SECRET_NAME}\")]" | jq -e '.[0]' >/dev/null; then
    echo "Secret already exists in bitwarden, skipping creation"
    exit 0
fi

# store the secret content as an item in bitwarden
echo "{\"organizationId\":null,\"folderId\":\"${FOLDER_ID}\",\"type\":2,\"name\":\"${SECRET_NAME}\",\"notes\":\"$(base64 -w 0 -i ${SECRET_PATH})\",\"favorite\":false,\"fields\":[],\"login\":null,\"secureNote\":{\"type\":0},\"card\":null,\"identity\":null}" | bw encode | bw create item
bw sync # optional
# retrieve  the secret
# assuming a single search result
bw list items --search "${SECRET_NAME}" | jq "[.[]? | select (.name==\"${SECRET_NAME}\")]"  | jq -r '.[0].notes' | base64 -d > ${SECRET_PATH}
# in case you're using chezmoi here's a template that will retrieve that secret automatically
#$cat $(chezmoi source-path ${SECRET_PATH})
#{{ (bitwarden "item" "${SECRET_NAME}").notes | b64dec }}
chezmoi execute-template "`cat $(chezmoi source-path ${SECRET_PATH})`"