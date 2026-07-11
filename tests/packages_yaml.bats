#!/usr/bin/env bats

load test_helper

PACKAGES_YAML="$BATS_TEST_DIRNAME/../.chezmoidata/packages.yaml"

# universal.{taps,brews,casks} is always installed alongside exactly one of
# work/private. A name listed in both universal and that branch ends up
# duplicated in the generated Brewfile, which makes `brew bundle` run
# `brew install`/`brew tap` twice for the same name and can fail with a
# "process has already locked" error.
overlap_with_universal() {
    local branch="$1" category="$2"
    comm -12 \
        <(yq -o=tsv ".packages.universal.$category[]" "$PACKAGES_YAML" | sort) \
        <(yq -o=tsv ".packages.$branch.$category[]" "$PACKAGES_YAML" | sort)
}

@test "no tap/brew/cask is listed in both universal and work" {
    for category in taps brews casks; do
        overlap=$(overlap_with_universal work "$category")
        [ -z "$overlap" ] || {
            echo "universal and work both list these $category: $overlap" >&2
            return 1
        }
    done
}

@test "no tap/brew/cask is listed in both universal and private" {
    for category in taps brews casks; do
        overlap=$(overlap_with_universal private "$category")
        [ -z "$overlap" ] || {
            echo "universal and private both list these $category: $overlap" >&2
            return 1
        }
    done
}
