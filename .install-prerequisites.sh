#!/bin/bash
set -ex

export PNPM_HOME="$HOME/.local/share/pnpm" # pnpm's global bin dir must be in PATH before `pnpm install -g` will run
export PATH="$PNPM_HOME/bin:$PATH"

case "$(uname -s)" in
Darwin)
    if type bw >/dev/null 2>&1; then
        echo "Bitwarden CLI is already installed"
    else
        brew install pnpm mise
        mise trust $HOME/.config/mise/config.toml && mise install node --verbose # Node is needed for pnpm
        eval "$(mise env -s bash)" # put mise-installed node on PATH for this script
        pnpm install -g @bitwarden/cli
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
        sudo apt-get update && sudo apt-get install -y mise
        mise trust $HOME/.config/mise/config.toml && mise install node --verbose # Node is needed for pnpm
        eval "$(mise env -s bash)" # put mise-installed node on PATH for this script
        pnpm install -g @bitwarden/cli
    fi
    ;;
*)
    echo "unsupported OS"
    exit 1
    ;;
esac