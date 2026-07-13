#!/bin/bash

set -ex

# This script installs everything from scratch. It is meant to be used through a curl to bash command.

# Install XCode Command Line Tools if necessary
xcode-select --install || echo "XCode already installed"

# Install Homebrew if necessary
if which -s brew; then
    echo 'Homebrew is already installed'
else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    (
        echo
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
    ) >>$HOME/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

brew install chezmoi

# .install-prerequisites.sh (run by chezmoi as a hook) installs node (via mise) and
# bw (via pnpm) into these directories. Exporting them here, before chezmoi runs,
# means chezmoi itself (and the ssh key template that shells out to bw) inherits
# this PATH too — env vars exported by the hook script don't propagate back up to
# the chezmoi process that spawned it.
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME/bin:$HOME/.local/share/mise/shims:$PATH"

CHEZMOI_INIT_SOURCE="${CHEZMOI_INIT_SOURCE:-marcore}"
chezmoi init "$CHEZMOI_INIT_SOURCE"

if [ "${CHEZMOI_APPLY:-true}" = "true" ]; then
    chezmoi apply
fi