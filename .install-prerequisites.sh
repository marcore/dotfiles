#!/bin/bash
set -ex

case "$(uname -s)" in
Darwin)
    if type bw >/dev/null 2>&1; then
        echo "Bitwarden CLI is already installed"
    else
        brew install pnpm
        npm install -g @bitwarden/cli
    fi

    if [ "${CI:-}" != "true" ]; then
        read -p "Please open Bitwarden, log into all accounts and set under Settings>CLI activate Integrate with Bitwarden CLI. Press any key to continue." -n 1 -r
        echo
    fi
    ;;
Linux)
    echo "Linux detected — skipping Homebrew"
    if ! type bw >/dev/null 2>&1; then
        curl -fsSL https://get.pnpm.io/install.sh | sh -
        pnpm install -g @bitwarden/cli
    fi
    ;;
*)
    echo "unsupported OS"
    exit 1
    ;;
esac