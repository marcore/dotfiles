# CI Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions CI that exercises `.initial-setup.sh`/`.install-prerequisites.sh` up through `chezmoi init` (no further, since `chezmoi apply` needs real Bitwarden auth) and runs the existing bats test suite, both on `macos-latest`.

**Architecture:** Two independent jobs in one workflow file. `.initial-setup.sh` gets a small, backward-compatible parameterization (two env-var overrides, both defaulting to today's real-world behavior) so CI can invoke the *actual* script file — not a re-implementation of its steps — while pointing it at the local checkout and skipping the final `chezmoi apply`.

**Tech Stack:** GitHub Actions (`macos-latest` runner), bash, chezmoi 2.71+, bats-core, yq (mikefarah).

## Global Constraints

- `.initial-setup.sh`'s real-world invocation (`curl ... | bash`, no env vars set) must produce byte-identical behavior to today: `CHEZMOI_INIT_SOURCE` defaults to `marcore`, `CHEZMOI_APPLY` defaults to `true`.
- CI must never attempt real `chezmoi apply` (it requires live Bitwarden auth for templated secrets) — the workflow stops at `chezmoi init`.
- CI must pre-seed `~/.config/chezmoi/chezmoi.toml`'s `[data]` block (`isWorkComputer`, `onedriveProjectsBackupDir`) before calling `chezmoi init`, since `promptBoolOnce`/`promptStringOnce` do not honor `--promptBool`/`--promptString` CLI flags in chezmoi 2.71.0 (verified: they still attempt to open `/dev/tty` and fail) — pre-seeding the config's `[data]` section is the only confirmed way to satisfy them non-interactively without editing `.chezmoi.toml.tmpl`.
- `.install-prerequisites.sh` is tested as its own explicit CI step (not via the `read-source-state.pre` hook, which does not fire during `chezmoi init` without `--apply`, confirmed by direct testing). Its `read -p` prompt must be satisfied by piping input, not by editing the script.
- Reference design doc: `docs/superpowers/specs/2026-07-11-ci-workflow-design.md`.

---

## Task 1: Parameterize `.initial-setup.sh`

**Files:**
- Modify: `.initial-setup.sh`

**Interfaces:**
- Produces: two env-var overrides consumed by the script — `CHEZMOI_INIT_SOURCE` (default `marcore`) and `CHEZMOI_APPLY` (default `true`, `chezmoi apply` runs only when this is exactly `true`).

- [ ] **Step 1: Make the change**

Read the current `.initial-setup.sh`:

```bash
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
chezmoi init marcore
chezmoi apply
```

Replace the last three lines (`brew install chezmoi` / `chezmoi init marcore` / `chezmoi apply`) with:

```bash
brew install chezmoi

CHEZMOI_INIT_SOURCE="${CHEZMOI_INIT_SOURCE:-marcore}"
chezmoi init "$CHEZMOI_INIT_SOURCE"

if [ "${CHEZMOI_APPLY:-true}" = "true" ]; then
    chezmoi apply
fi
```

- [ ] **Step 2: Verify manually (no bats test — this exercises real chezmoi/homebrew/Bitwarden state, which isn't safe or meaningful to automate as a unit test; the real regression protection is Task 2's CI job actually going green)**

Confirm the change preserves real-world behavior and supports the CI override, using a disposable scratch source directory so nothing touches your real chezmoi state:

```bash
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/source" "$SCRATCH/home/.config/chezmoi"
git -C "$SCRATCH/source" init -q
cat > "$SCRATCH/source/.chezmoi.toml.tmpl" <<'EOF'
{{- $isWorkComputer := promptBoolOnce . "isWorkComputer" "Is this your work computer" -}}
{{- $onedriveProjectsBackupDir := promptStringOnce . "onedriveProjectsBackupDir" "Path to OneDrive backup dir" -}}

[data]
    isWorkComputer = {{ $isWorkComputer }}
    onedriveProjectsBackupDir = {{ $onedriveProjectsBackupDir | quote }}
EOF
git -C "$SCRATCH/source" add .chezmoi.toml.tmpl
git -C "$SCRATCH/source" -c user.email=test@test.com -c user.name=test commit -q -m init
cat > "$SCRATCH/home/.config/chezmoi/chezmoi.toml" <<'EOF'
[data]
    isWorkComputer = false
    onedriveProjectsBackupDir = "/tmp/onedrive-ci"
EOF

HOME="$SCRATCH/home" CHEZMOI_INIT_SOURCE="$SCRATCH/source" CHEZMOI_APPLY=false bash -c '
  brew install chezmoi >/dev/null 2>&1 || true
  CHEZMOI_INIT_SOURCE="${CHEZMOI_INIT_SOURCE:-marcore}"
  chezmoi init "$CHEZMOI_INIT_SOURCE"
  if [ "${CHEZMOI_APPLY:-true}" = "true" ]; then
    echo "WOULD HAVE RUN chezmoi apply"
  fi
'
echo "exit=$?"
cat "$SCRATCH/home/.config/chezmoi/chezmoi.toml"
rm -rf "$SCRATCH"
```

Expected: exit code 0, no "WOULD HAVE RUN chezmoi apply" line printed (since `CHEZMOI_APPLY=false`), and the printed `chezmoi.toml` still shows `isWorkComputer = false` / `onedriveProjectsBackupDir = "/tmp/onedrive-ci"` (i.e. `chezmoi init` ran successfully against the local source, no interactive prompt, no `/dev/tty` error).

Then confirm the *default* (real-world) path is unchanged by inspecting the diff: with no env vars set, `CHEZMOI_INIT_SOURCE` still defaults to `marcore` and `CHEZMOI_APPLY` still defaults to `true`, so `chezmoi init marcore && chezmoi apply` behavior for a real new-laptop run is identical to before this change.

- [ ] **Step 3: Commit**

```bash
git add .initial-setup.sh
git commit -m "$(cat <<'EOF'
Parameterize .initial-setup.sh's chezmoi source and apply step

Lets CI point chezmoi init at the local checkout instead of cloning
the live GitHub repo, and skip the final chezmoi apply (which needs
real Bitwarden auth). Both overrides default to today's real-world
behavior when unset.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `.initial-setup.sh`'s `CHEZMOI_INIT_SOURCE`/`CHEZMOI_APPLY` overrides from Task 1; `.install-prerequisites.sh` (unchanged); `tests/*.bats` (existing).

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  setup:
    name: Initial setup & prerequisites
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Pre-seed chezmoi config (avoids interactive prompts)
        run: |
          mkdir -p "$HOME/.config/chezmoi"
          cat > "$HOME/.config/chezmoi/chezmoi.toml" <<'EOF'
          [data]
              isWorkComputer = false
              onedriveProjectsBackupDir = "/tmp/onedrive-ci"
          EOF

      - name: Run .install-prerequisites.sh
        run: yes '' | ./.install-prerequisites.sh

      - name: Run .initial-setup.sh up through chezmoi init
        env:
          CHEZMOI_INIT_SOURCE: ${{ github.workspace }}
          CHEZMOI_APPLY: "false"
        run: ./.initial-setup.sh

      - name: Show resolved chezmoi config
        run: chezmoi cat-config

  bats:
    name: Bats tests
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install test tooling
        run: brew install bats-core yq

      - name: Run bats tests
        run: bats tests/
```

- [ ] **Step 2: Verify locally as far as possible**

Run:
```bash
bats tests/
```
Expected: 17/17 passing (this is exactly what the `bats` job will run in CI — confirming it passes locally now means the job's core command is known-good; the workflow YAML syntax itself is verified by Step 3).

Run (YAML syntax sanity check, no GitHub API call):
```bash
python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "valid YAML"
```
Expected: `valid YAML`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
Add CI workflow for setup scripts and bats tests

Two macos-latest jobs: one runs .install-prerequisites.sh and
.initial-setup.sh through chezmoi init (stopping short of chezmoi
apply, which needs real Bitwarden auth), the other runs the bats
test suite.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Note for the user**

This workflow will only actually run on GitHub once the repo is pushed to `origin` (per earlier session context, this repo hasn't been pushed yet, and push access wasn't available from this environment). Mention this in the final report — verifying the workflow goes green on GitHub itself is something the user needs to observe after pushing, not something achievable from this local environment.
