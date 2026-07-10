# dotfiles

Personal dotfiles managed with [chezmoi](https://www.chezmoi.io/), so a new Mac can be brought to a working state quickly and reproducibly.

## What this manages

- **Shell & git config:** `dot_zshrc`, `dot_gitconfig.tmpl`, `dot_gitignore_global`, `dot_config/gh`
- **SSH keys:** `private_dot_ssh/` — private keys are templated and pulled from Bitwarden at apply time, not stored in the repo
- **Packages:** `.chezmoidata/packages.yaml` declares Homebrew taps/formulae/casks (universal + work-only), applied via `run_onchange_darwin-install-packages.sh.tmpl`
- **Browser:** Chrome bookmarks and extensions are exported/restored via `export-bookmarks.sh` / `export-extensions.sh` and `run_once_after_*` scripts
- **`$HOME/Projects`:** git repos, plain project folders, and their gitignored secrets (`.env`, credentials) — see below

Secrets never live in this repo. They're stored in Bitwarden (`add_secret_to_bw.sh` and the `[bitwarden]` chezmoi integration) and pulled down on demand via `{{ (bitwarden "item" "...").notes | b64dec }}` templates.

## Projects backup & restore

`$HOME/Projects` holds development work — some git repos, some plain folders. A curated inventory of what matters lives in `.chezmoidata/projects.yaml` and drives four scripts:

| Script | Runs on | Purpose |
|---|---|---|
| `scan_repos.sh` | either | Scans a directory tree and prints a YAML inventory of git repos (with remotes/status/ignored files) and plain folder roots (with any nested repos) |
| `export-project-secrets.sh` | old laptop | Pushes each curated repo's gitignored secret files to Bitwarden |
| `export-project-folders.sh` | old laptop | Zips each curated plain-folder root to a OneDrive backup dir |
| `restore-projects.sh` | new laptop | Clones repos, restores secrets from Bitwarden, unzips folders, and clones nested repos back into place (`--dry-run` supported) |

These are manual scripts, not wired into `chezmoi apply` — rebuilding `$HOME/Projects` is a deliberate step, not something that happens silently. See `docs/superpowers/specs/2026-07-10-projects-backup-restore-design.md` for the design rationale.

To refresh the curated list: run `./scan_repos.sh "$HOME/Projects"`, copy the output into `.chezmoidata/projects.yaml`, and prune it down to what's actually worth backing up.

## Setting up a new laptop

```sh
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install chezmoi
chezmoi init marcore
chezmoi apply
```

(`.initial-setup.sh` automates the above.) During `chezmoi init` you'll be prompted for a few values (e.g. whether this is a work computer, the OneDrive backup folder path) and Bitwarden will be used to pull down SSH keys and other secrets.

Once the machine is set up and SSH/Bitwarden are working, restore your projects:

```sh
./restore-projects.sh --dry-run   # preview
./restore-projects.sh             # for real
```

## Tests

Shell scripts are covered by [bats-core](https://github.com/bats-core/bats-core):

```sh
bats tests/
```
