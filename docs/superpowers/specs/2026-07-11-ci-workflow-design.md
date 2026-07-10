# CI workflow for setup scripts and bats tests — design

## Problem

This repo has no CI. Two things are worth automatically verifying on every
push/PR:

1. `.initial-setup.sh` and `.install-prerequisites.sh` — the scripts a new
   Mac actually runs to bootstrap this dotfiles setup — still work.
2. The bats test suite under `tests/` (`scan_repos.sh`,
   `export-project-secrets.sh`, `export-project-folders.sh`,
   `restore-projects.sh`) still passes.

## Constraints that shape the design

- `.initial-setup.sh` ends with `chezmoi init marcore && chezmoi apply`.
  `chezmoi init marcore` clones `github.com/marcore/dotfiles` — the *live*
  remote, not whatever's checked out locally. Running that as-is in CI would
  test whatever is currently pushed to GitHub, not the branch/PR under test.
- `chezmoi apply` renders templated files (`private_dot_ssh/*.tmpl`, chrome
  restore scripts) that call out to Bitwarden
  (`{{ (bitwarden "item" "...").notes | b64dec }}`). There is no safe way to
  give a CI runner real access to a personal Bitwarden vault, so `chezmoi
  apply` cannot run for real in CI.
- `.chezmoi.toml.tmpl` prompts interactively for `isWorkComputer` and
  `onedriveProjectsBackupDir` via `promptBoolOnce`/`promptStringOnce`.
- `.chezmoi.toml.tmpl`'s `[hooks.read-source-state.pre]` runs
  `.install-prerequisites.sh` during `chezmoi init` itself, which contains a
  blocking `read -p "Please open Bitwarden..."` prompt.
- GitHub's `macos-latest` runners already ship Xcode Command Line Tools and
  Homebrew, so the "not installed yet" branches of `.initial-setup.sh` won't
  be exercised in CI — only the "already installed" branches will run. This
  is an accepted limitation, not something this design works around.

## Scope

- Test `.initial-setup.sh` and `.install-prerequisites.sh` up through
  `chezmoi init` only. `chezmoi apply` is explicitly out of scope for CI.
- Point `chezmoi init` at the local checkout instead of the live GitHub repo.
- Run the existing bats suite (`tests/`) unmodified.

## Design

### 1. Parameterize `.initial-setup.sh`'s chezmoi source

Change the hardcoded line:
```bash
chezmoi init marcore
```
to:
```bash
CHEZMOI_INIT_SOURCE="${CHEZMOI_INIT_SOURCE:-marcore}"
chezmoi init "$CHEZMOI_INIT_SOURCE"
```
Real-world usage (`curl ... | bash` with no env var set) is unchanged —
`CHEZMOI_INIT_SOURCE` defaults to `marcore`, same as today. CI sets
`CHEZMOI_INIT_SOURCE` to the local checkout path, so `chezmoi init` uses
`chezmoi init /path/to/checkout` (a local directory, not a remote clone).

Also remove the trailing `chezmoi apply` from the *tested* path: rather than
editing the script to conditionally skip apply (which would complicate a
script meant to "just work" for a real user), the CI job invokes the setup
steps up through `chezmoi init` directly, matching what `.initial-setup.sh`
does through that point, and does not additionally run `chezmoi apply`. See
"Job 1" below for the exact invocation.

### 2. GitHub Actions workflow: `.github/workflows/ci.yml`

Two jobs, both `runs-on: macos-latest`, triggered on `push` and
`pull_request`.

**Job `setup`:**
1. Checkout the repo.
2. Run `.initial-setup.sh` up through `brew install chezmoi`, with
   `CHEZMOI_INIT_SOURCE` set to the checkout path, and with
   `chezmoi init` itself invoked with:
   - `--promptBool isWorkComputer=false`
   - `--promptString onedriveProjectsBackupDir=/tmp/onedrive-ci`
   - stdin piped from `yes ''` so `.install-prerequisites.sh`'s
     `read -p` (fired as the `read-source-state.pre` hook) doesn't hang.
3. Do not run `chezmoi apply`.

**Job `bats`:**
1. Checkout the repo.
2. `brew install bats-core yq` (jq/git/zip are already present on the
   runner).
3. `bats tests/`.

## Testing

The workflow's own correctness is verified by pushing it and observing both
jobs go green on GitHub Actions — there's no meaningful local unit test for
a CI workflow file beyond that. The `.initial-setup.sh` parameterization is
a two-line, backward-compatible change; no new bats test is needed for it
since CI running the job green *is* the test.
