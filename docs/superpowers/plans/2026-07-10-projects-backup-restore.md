# Projects Folder Backup & Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `$HOME/Projects` (git repos, plain folders, and gitignored secret files) be reconstructed on a new laptop from data committed in this dotfiles repo, Bitwarden, and a OneDrive shared folder.

**Architecture:** `scan_repos.sh` is reworked to model plain folders as "roots" with a `nested_repos` exclusion list. The user manually curates a `.chezmoidata/projects.yaml` from its output. Two new "export" scripts (run manually on the old laptop) push gitignored secret files into Bitwarden and zip plain-folder roots into OneDrive. One new "restore" script (run manually on the new laptop) clones repos, restores secrets from Bitwarden, unzips folders from OneDrive, and clones nested repos back into place.

**Tech Stack:** Bash (`set -euo pipefail`), `yq` (mikefarah/yq, Go implementation) for YAML parsing, `jq` for JSON parsing of Bitwarden CLI output, `git`, `zip`/`unzip`, `bw` (Bitwarden CLI), `bats-core` for tests.

## Global Constraints

- All new scripts use `#!/usr/bin/env bash` and `set -euo pipefail`, matching `add_secret_to_bw.sh` and `export-bookmarks.sh`.
- Manual export/restore scripts are never invoked automatically by chezmoi (no `run_once_*` wiring) — cloning many repos and unzipping archives must stay deliberate, per the approved design.
- `.chezmoidata/projects.yaml` schema (top-level keys: `root`, `repos`, `folders`) matches `scan_repos.sh`'s (reworked) output verbatim, since it's produced by copy-and-prune.
- Bitwarden secret item naming: `proj-secret:<repo-path-relative-to-root>:<file-relative-path>` (e.g. `proj-secret:ENI/cf-extension-demo:.env`), created via the existing `add_secret_to_bw.sh`.
- Zip archive naming: folder root path relative to `root`, with `/` replaced by `-`, plus `.zip` (e.g. `EY-fakejobfailurebundle.zip`).
- Reference design doc: `docs/superpowers/specs/2026-07-10-projects-backup-restore-design.md`.

---

## Task 1: Rework `scan_repos.sh` folder detection to a roots + nested_repos model

**Files:**
- Modify: `scan_repos.sh`
- Modify: `.chezmoidata/packages.yaml` (add `bats-core` to `packages.universal.brews`)
- Create: `tests/test_helper.bash`
- Create: `tests/scan_repos.bats`

**Interfaces:**
- Produces: `scan_repos.sh <ROOT_DIR> [MAX_JOBS]` YAML output where `folders:` entries are now maps: `{path: <abs path>, nested_repos: [<relative paths>]}` instead of bare path scalars. `repos:` schema is unchanged.
- Produces (test_helper.bash): `make_git_repo <dir> [remote_url]`, `make_bare_repo <dir>`, `make_plain_dir_with_file <dir> [filename]` — used by all later test files in this plan.

- [ ] **Step 1: Install test tooling locally**

Run:
```bash
brew install bats-core
```
Expected: `bats-core` installed; `bats --version` prints a version (e.g. `Bats 1.13.0`). (`yq` is already declared in `packages.yaml`; install it too if `yq --version` doesn't already print `yq (https://github.com/mikefarah/yq/) version v4.x.x`: `brew install yq`.)

- [ ] **Step 2: Declare `bats-core` in `packages.yaml` for future machines**

In `.chezmoidata/packages.yaml`, under `packages.universal.brews`, insert `"bats-core"` right after `"bat"` (keeping the existing alphabetical-ish ordering):

```yaml
        brews:
            - "bash"
            - "bat"
            - "bats-core"
            - "chezmoi"
```

- [ ] **Step 3: Create the shared test helper**

Create `tests/test_helper.bash`:

```bash
# Shared helpers for bats tests in this repo.

# Create a git repo at $1 with an initial commit, optionally with a remote
# named "origin" pointing at $2.
make_git_repo() {
    local dir="$1" remote_url="${2:-}"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test User"
    echo "hello" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial commit"
    if [[ -n "$remote_url" ]]; then
        git -C "$dir" remote add origin "$remote_url"
    fi
}

# Create a bare repo at $1 with one commit on "main", usable as a clone
# source in tests (no network required).
make_bare_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git init -q --bare "$dir"
    local tmp_clone
    tmp_clone=$(mktemp -d)
    git clone -q "$dir" "$tmp_clone"
    git -C "$tmp_clone" config user.email "test@example.com"
    git -C "$tmp_clone" config user.name "Test User"
    echo "hello" > "$tmp_clone/README.md"
    git -C "$tmp_clone" add README.md
    git -C "$tmp_clone" commit -q -m "initial commit"
    git -C "$tmp_clone" push -q origin HEAD:main
    git -C "$dir" symbolic-ref HEAD refs/heads/main
    rm -rf "$tmp_clone"
}

# Create a plain (non-git) directory at $1 containing one file.
make_plain_dir_with_file() {
    local dir="$1" filename="${2:-notes.txt}"
    mkdir -p "$dir"
    echo "content" > "$dir/$filename"
}
```

- [ ] **Step 4: Write the failing tests**

Create `tests/scan_repos.bats`:

```bash
#!/usr/bin/env bats

load test_helper

SCAN_REPOS="$BATS_TEST_DIRNAME/../scan_repos.sh"

setup() {
    PROJECTS_DIR="$BATS_TEST_TMPDIR/Projects"
    mkdir -p "$PROJECTS_DIR"
}

@test "reports a single root for a plain folder with files at multiple nested levels" {
    make_plain_dir_with_file "$PROJECTS_DIR/EY/fakejobfailurebundle" "README.md"
    make_plain_dir_with_file "$PROJECTS_DIR/EY/fakejobfailurebundle/core" "pom.xml"
    make_plain_dir_with_file "$PROJECTS_DIR/EY/fakejobfailurebundle/core/src/main/java/com/ey/core/jobs" "Job.java"

    run "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    count=$(yq '.folders | length' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$count" -eq 1 ]

    path=$(yq '.folders[0].path' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$path" = "$PROJECTS_DIR/EY/fakejobfailurebundle" ]
}

@test "records a nested git repo under a folder root as nested_repos, and still lists it under repos" {
    make_plain_dir_with_file "$PROJECTS_DIR/EY/fakejobfailurebundle" "README.md"
    make_git_repo "$PROJECTS_DIR/EY/fakejobfailurebundle/vendor/widget" "git@example.com:me/widget.git"

    run "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    nested=$(yq '.folders[0].nested_repos[0]' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$nested" = "vendor/widget" ]

    repo_path=$(yq '.repos[0].path' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$repo_path" = "$PROJECTS_DIR/EY/fakejobfailurebundle/vendor/widget" ]
}

@test "folder root with no nested repos reports nested_repos as an empty list" {
    make_plain_dir_with_file "$PROJECTS_DIR/EY/plainproj" "notes.txt"

    run "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    nested_type=$(yq '.folders[0].nested_repos | type' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$nested_type" = "!!seq" ]
    nested_len=$(yq '.folders[0].nested_repos | length' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$nested_len" -eq 0 ]
}

@test "existing repo detection (remotes, clean status) is unchanged" {
    make_git_repo "$PROJECTS_DIR/ENI/cf-extension-demo" "git@github.com:marcore/cf-extension-demo.git"

    run "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    remote_name=$(yq '.repos[0].remotes[0].name' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$remote_name" = "origin" ]
    remote_url=$(yq '.repos[0].remotes[0].url' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$remote_url" = "git@github.com:marcore/cf-extension-demo.git" ]
    status_val=$(yq '.repos[0].status' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$status_val" = "clean" ]
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `bats tests/scan_repos.bats`
Expected: FAIL on the first three tests (current `folders:` output is a flat list of bare path scalars, e.g. `.folders[0].path` errors because `.folders[0]` is a string, not a map). The fourth test (repo detection) should already PASS since it's unaffected by this change — confirming the harness works before touching repo logic.

- [ ] **Step 6: Implement the roots + nested_repos rework**

In `scan_repos.sh`, add a new helper function right after `yaml_quote` (before `scan_directory`):

```bash
# Find git repos nested inside a folder root, printed as paths relative to
# that root (one per line). Used to populate a root's nested_repos list so
# export tooling can exclude them from the root's zip archive.
find_nested_repos() {
    local root="$1"
    find "$root" -mindepth 1 -type d -name .git 2>/dev/null | while IFS= read -r gitdir; do
        local repo_dir="${gitdir%/.git}"
        echo "${repo_dir#"$root"/}"
    done
}
```

Replace the body of `scan_directory` (the whole function) with:

```bash
scan_directory() {
    local dir="$1" repo_out="$2" folder_out="$3" in_root="${4:-0}"

    if [[ -d "$dir/.git" ]]; then
        {
            echo "  - path: $(yaml_quote "$dir")"

            local remote_names
            remote_names=$(git -C "$dir" remote 2>/dev/null || true)
            if [[ -n "$remote_names" ]]; then
                echo "    remotes:"
                while IFS= read -r name; do
                    local url
                    url=$(git -C "$dir" remote get-url "$name" 2>/dev/null)
                    echo "      - name: $(yaml_quote "$name")"
                    echo "        url: $(yaml_quote "$url")"
                done <<< "$remote_names"
            else
                echo "    remotes: []"
            fi

            local porcelain
            porcelain=$(git -C "$dir" status --porcelain 2>/dev/null || true)
            if [[ -n "$porcelain" ]]; then
                local total
                total=$(echo "$porcelain" | wc -l | tr -d ' ')
                echo "    status: dirty"
                echo "    dirty_count: $total"
                echo "    dirty_files:"
                while IFS= read -r line; do
                    echo "      - $(yaml_quote "$line")"
                done <<< "$porcelain"
            else
                echo "    status: clean"
            fi

            local ignored
            ignored=$(git -C "$dir" ls-files --others --ignored --exclude-standard 2>/dev/null \
                | grep -vE "$IGNORED_DIR_PATTERN" || true)
            if [[ -n "$ignored" ]]; then
                echo "    ignored_files:"
                while IFS= read -r line; do
                    echo "      - $(yaml_quote "$line")"
                done <<< "$ignored"
            else
                echo "    ignored_files: []"
            fi
        } >> "$repo_out"

        # Do not recurse further into a repo
        return
    fi

    # Non-repo directory: if we're not already inside a discovered folder
    # root, check whether this dir is itself a root (directly contains
    # files, ignoring filenames that match IGNORED_FILE_PATTERN).
    if [[ "$in_root" -eq 0 ]]; then
        local has_files
        has_files=$(find "$dir" -maxdepth 1 -mindepth 1 -type f -print0 2>/dev/null \
            | xargs -0 -n1 basename 2>/dev/null \
            | grep -vE "$IGNORED_FILE_PATTERN" | head -1)
        if [[ -n "$has_files" ]]; then
            {
                echo "  - path: $(yaml_quote "$dir")"
                local nested
                nested=$(find_nested_repos "$dir")
                if [[ -n "$nested" ]]; then
                    echo "    nested_repos:"
                    while IFS= read -r rel; do
                        echo "      - $(yaml_quote "$rel")"
                    done <<< "$nested"
                else
                    echo "    nested_repos: []"
                fi
            } >> "$folder_out"
            in_root=1
        fi
    fi

    while IFS= read -r -d '' subdir; do
        local name
        name="$(basename "$subdir")"
        should_skip "$name" && continue
        scan_directory "$subdir" "$repo_out" "$folder_out" "$in_root"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bats tests/scan_repos.bats`
Expected: PASS (4 tests, 0 failures)

- [ ] **Step 8: Commit**

```bash
git add scan_repos.sh .chezmoidata/packages.yaml tests/test_helper.bash tests/scan_repos.bats
git commit -m "$(cat <<'EOF'
Rework scan_repos.sh folders to a roots + nested_repos model

Plain folders are now reported once per project root instead of once
per nested directory with files, with any git repos found inside a
root recorded separately so export tooling can exclude them from the
root's zip backup.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `onedriveProjectsBackupDir` config value

**Files:**
- Modify: `.chezmoi.toml.tmpl`

**Interfaces:**
- Produces: a `onedriveProjectsBackupDir` chezmoi data value, readable by later scripts via `chezmoi data | jq -r '.onedriveProjectsBackupDir'`.

- [ ] **Step 1: Add the prompt and data value**

In `.chezmoi.toml.tmpl`, change:

```
{{- $isWorkComputer := promptBoolOnce . "isWorkComputer" "Is this your work computer" -}}

[data]
    isWorkComputer = {{ $isWorkComputer }}
```

to:

```
{{- $isWorkComputer := promptBoolOnce . "isWorkComputer" "Is this your work computer" -}}
{{- $onedriveProjectsBackupDir := promptStringOnce . "onedriveProjectsBackupDir" "Path to the OneDrive folder for Projects zip backups" -}}

[data]
    isWorkComputer = {{ $isWorkComputer }}
    onedriveProjectsBackupDir = {{ $onedriveProjectsBackupDir | quote }}
```

- [ ] **Step 2: Verify manually (not automatable — `promptStringOnce` mutates your real, persistent chezmoi config, so this must not be run from an automated test)**

Run: `chezmoi cat-config`
Expected: the command succeeds and, since `.chezmoi.toml.tmpl` is only evaluated by `chezmoi init` (not by `cat-config`), this step is purely a static review — re-read the diff and confirm the TOML syntax mirrors the existing `isWorkComputer` block exactly (same indentation, same quoting style). Do not run `chezmoi init` against your real machine as part of this task; that will happen naturally the next time you actually re-init or on the new laptop.

- [ ] **Step 3: Commit**

```bash
git add .chezmoi.toml.tmpl
git commit -m "$(cat <<'EOF'
Add onedriveProjectsBackupDir chezmoi config value

Needed by the upcoming export/restore scripts to locate the OneDrive
shared folder used for plain-folder zip backups.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Create `export-project-secrets.sh`

**Files:**
- Create: `export-project-secrets.sh`
- Create: `tests/export-project-secrets.bats`

**Interfaces:**
- Consumes: `.chezmoidata/projects.yaml` schema from Task 1 (`root`, `repos[].path`, `repos[].ignored_files[]`); `add_secret_to_bw.sh <name> <path>` (existing, unchanged).
- Produces: `export-project-secrets.sh [PROJECTS_YAML]` (defaults to `.chezmoidata/projects.yaml` next to the script); for each existing ignored file, invokes `$ADD_SECRET_SCRIPT <secret_name> <secret_path>` where `ADD_SECRET_SCRIPT` defaults to `add_secret_to_bw.sh` next to the script but is overridable via env var for testing. Secret name format: `proj-secret:<repo-path-relative-to-root>:<file-relative-path>`.

- [ ] **Step 1: Write the failing tests**

Create `tests/export-project-secrets.bats`:

```bash
#!/usr/bin/env bats

load test_helper

EXPORT_SECRETS="$BATS_TEST_DIRNAME/../export-project-secrets.sh"

setup() {
    WORK="$BATS_TEST_TMPDIR"
    PROJECTS_ROOT="$WORK/Projects"
    mkdir -p "$PROJECTS_ROOT"

    FAKE_LOG="$WORK/add_secret_calls.log"
    : > "$FAKE_LOG"
    cat > "$WORK/fake_add_secret.sh" <<EOF
#!/usr/bin/env bash
echo "\$1|\$2" >> "$FAKE_LOG"
EOF
    chmod +x "$WORK/fake_add_secret.sh"
    export ADD_SECRET_SCRIPT="$WORK/fake_add_secret.sh"
}

@test "exports each existing ignored file with the proj-secret naming convention" {
    repo_dir="$PROJECTS_ROOT/ENI/cf-extension-demo"
    mkdir -p "$repo_dir"
    echo "SECRET=1" > "$repo_dir/.env"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$repo_dir"
    remotes: []
    ignored_files:
      - ".env"
folders: []
EOF

    run "$EXPORT_SECRETS" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]

    grep -qF "proj-secret:ENI/cf-extension-demo:.env|$repo_dir/.env" "$FAKE_LOG"
}

@test "skips ignored files that no longer exist locally" {
    repo_dir="$PROJECTS_ROOT/ENI/gone"
    mkdir -p "$repo_dir"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$repo_dir"
    remotes: []
    ignored_files:
      - ".env"
folders: []
EOF

    run "$EXPORT_SECRETS" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping proj-secret:ENI/gone:.env"* ]]
    [ ! -s "$FAKE_LOG" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/export-project-secrets.bats`
Expected: FAIL with "No such file or directory" (`export-project-secrets.sh` doesn't exist yet)

- [ ] **Step 3: Write the implementation**

Create `export-project-secrets.sh`:

```bash
#!/usr/bin/env bash
#
# export-project-secrets.sh
#
# Run this MANUALLY on the OLD laptop, from the root of your dotfiles repo,
# whenever you refresh the set of gitignored "secret" files (.env, credential
# files, ...) that need to survive a laptop migration.
#
# Reads .chezmoidata/projects.yaml and, for every repo's ignored_files entry,
# pushes the file's content into Bitwarden as a secure note via
# add_secret_to_bw.sh, using the naming convention:
#
#   proj-secret:<repo-path-relative-to-projects-root>:<file-relative-path>
#
# add_secret_to_bw.sh already skips creation if the Bitwarden item exists,
# so re-running this after editing projects.yaml is safe.
#
# Usage:
#   ./export-project-secrets.sh [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_YAML="${1:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"
ADD_SECRET_SCRIPT="${ADD_SECRET_SCRIPT:-$SCRIPT_DIR/add_secret_to_bw.sh}"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi

projects_root=$(yq '.root' "$PROJECTS_YAML")
repo_count=$(yq '.repos | length' "$PROJECTS_YAML")

for ((i = 0; i < repo_count; i++)); do
    repo_path=$(yq ".repos[$i].path" "$PROJECTS_YAML")
    repo_rel="${repo_path#"$projects_root"/}"

    file_count=$(yq ".repos[$i].ignored_files | length" "$PROJECTS_YAML")
    for ((j = 0; j < file_count; j++)); do
        file_rel=$(yq ".repos[$i].ignored_files[$j]" "$PROJECTS_YAML")
        secret_path="$repo_path/$file_rel"
        secret_name="proj-secret:${repo_rel}:${file_rel}"

        if [[ ! -f "$secret_path" ]]; then
            echo "Skipping $secret_name: $secret_path not found locally"
            continue
        fi

        echo "Exporting $secret_name"
        "$ADD_SECRET_SCRIPT" "$secret_name" "$secret_path"
    done
done
```

Run: `chmod +x export-project-secrets.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/export-project-secrets.bats`
Expected: PASS (2 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add export-project-secrets.sh tests/export-project-secrets.bats
git commit -m "$(cat <<'EOF'
Add export-project-secrets.sh

Manual script for the old laptop: pushes each curated repo's gitignored
secret files into Bitwarden via add_secret_to_bw.sh, named
proj-secret:<repo>:<file>.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Create `export-project-folders.sh`

**Files:**
- Create: `export-project-folders.sh`
- Create: `tests/export-project-folders.bats`

**Interfaces:**
- Consumes: `.chezmoidata/projects.yaml` schema (`root`, `folders[].path`, `folders[].nested_repos[]`); `onedriveProjectsBackupDir` value (via `$ONEDRIVE_PROJECTS_BACKUP_DIR` env override or `chezmoi data`).
- Produces: `export-project-folders.sh [PROJECTS_YAML]`; writes `<archive-name>.zip` files into the OneDrive backup dir, named `<root-relative-path with / replaced by ->.zip`.

- [ ] **Step 1: Write the failing test**

Create `tests/export-project-folders.bats`:

```bash
#!/usr/bin/env bats

load test_helper

EXPORT_FOLDERS="$BATS_TEST_DIRNAME/../export-project-folders.sh"

setup() {
    WORK="$BATS_TEST_TMPDIR"
    PROJECTS_ROOT="$WORK/Projects"
    ONEDRIVE_DIR="$WORK/onedrive"
    mkdir -p "$PROJECTS_ROOT" "$ONEDRIVE_DIR"
    export ONEDRIVE_PROJECTS_BACKUP_DIR="$ONEDRIVE_DIR"
}

@test "zips a folder root, excluding a nested repo's contents" {
    folder="$PROJECTS_ROOT/EY/fakejobfailurebundle"
    mkdir -p "$folder"
    echo "hi" > "$folder/README.md"
    mkdir -p "$folder/vendor/widget"
    echo "secret-ish" > "$folder/vendor/widget/file.txt"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos: []
folders:
  - path: "$folder"
    nested_repos:
      - "vendor/widget"
EOF

    run "$EXPORT_FOLDERS" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]

    archive="$ONEDRIVE_DIR/EY-fakejobfailurebundle.zip"
    [ -f "$archive" ]

    listing=$(unzip -Z1 "$archive")
    [[ "$listing" == *"fakejobfailurebundle/README.md"* ]]
    [[ "$listing" != *"vendor/widget/file.txt"* ]]
}

@test "warns and skips a folder root that no longer exists locally" {
    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos: []
folders:
  - path: "$PROJECTS_ROOT/EY/gone"
    nested_repos: []
EOF

    run "$EXPORT_FOLDERS" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: folder not found, skipping"* ]]
    [ ! -f "$ONEDRIVE_DIR/EY-gone.zip" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/export-project-folders.bats`
Expected: FAIL with "No such file or directory" (`export-project-folders.sh` doesn't exist yet)

- [ ] **Step 3: Write the implementation**

Create `export-project-folders.sh`:

```bash
#!/usr/bin/env bash
#
# export-project-folders.sh
#
# Run this MANUALLY on the OLD laptop, from the root of your dotfiles repo,
# whenever you want to refresh the zip archives of your curated plain
# (non-git) project folders.
#
# Reads .chezmoidata/projects.yaml and, for each entry under `folders:`,
# zips that folder into the OneDrive backup dir, excluding any
# nested_repos (those are restored separately via git clone by
# restore-projects.sh).
#
# Usage:
#   ./export-project-folders.sh [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml
#   Backup dir comes from $ONEDRIVE_PROJECTS_BACKUP_DIR, falling back to
#   the onedriveProjectsBackupDir chezmoi data value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_YAML="${1:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"
ONEDRIVE_DIR="${ONEDRIVE_PROJECTS_BACKUP_DIR:-$(chezmoi data 2>/dev/null | jq -r '.onedriveProjectsBackupDir // empty')}"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi
if [[ -z "$ONEDRIVE_DIR" ]]; then
    echo "Error: onedriveProjectsBackupDir is not set (chezmoi data) and \$ONEDRIVE_PROJECTS_BACKUP_DIR is not set" >&2
    exit 1
fi
mkdir -p "$ONEDRIVE_DIR"

projects_root=$(yq '.root' "$PROJECTS_YAML")
folder_count=$(yq '.folders | length' "$PROJECTS_YAML")

for ((i = 0; i < folder_count; i++)); do
    folder_path=$(yq ".folders[$i].path" "$PROJECTS_YAML")
    folder_name="$(basename "$folder_path")"
    parent_dir="$(dirname "$folder_path")"
    archive_name="$(echo "${folder_path#"$projects_root"/}" | tr '/' '-').zip"
    archive_path="$ONEDRIVE_DIR/$archive_name"

    if [[ ! -d "$folder_path" ]]; then
        echo "WARN: folder not found, skipping: $folder_path" >&2
        continue
    fi

    exclude_args=()
    nested_count=$(yq ".folders[$i].nested_repos | length" "$PROJECTS_YAML")
    for ((j = 0; j < nested_count; j++)); do
        nested_rel=$(yq ".folders[$i].nested_repos[$j]" "$PROJECTS_YAML")
        exclude_args+=(-x "$folder_name/$nested_rel/*")
    done

    rm -f "$archive_path"
    (cd "$parent_dir" && zip -qr "$archive_path" "$folder_name" "${exclude_args[@]}")
    echo "Exported $folder_path -> $archive_path"
done
```

Run: `chmod +x export-project-folders.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/export-project-folders.bats`
Expected: PASS (2 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add export-project-folders.sh tests/export-project-folders.bats
git commit -m "$(cat <<'EOF'
Add export-project-folders.sh

Manual script for the old laptop: zips each curated plain folder root
into the OneDrive backup dir, excluding any nested git repos (those
are restored separately via clone).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Create `restore-projects.sh` — clone top-level repos, skip existing, `--dry-run`

**Files:**
- Create: `restore-projects.sh`
- Create: `tests/restore-projects.bats`

**Interfaces:**
- Consumes: `.chezmoidata/projects.yaml` schema (`root`, `repos[].path`, `repos[].remotes[0].url`).
- Produces: `restore-projects.sh [--dry-run] [PROJECTS_YAML]`. Internal functions later tasks extend: `restore_repo <index>` (clones repo at `repos[index]` if missing), `is_nested_repo <repo_path>` (true if `repo_path` is inside any `folders[].path`), `run <cmd...>` (executes, or echoes `DRY-RUN: ...` under `--dry-run`).

- [ ] **Step 1: Write the failing tests**

Create `tests/restore-projects.bats`:

```bash
#!/usr/bin/env bats

load test_helper

RESTORE="$BATS_TEST_DIRNAME/../restore-projects.sh"

setup() {
    WORK="$BATS_TEST_TMPDIR"
    PROJECTS_ROOT="$WORK/Projects"
    ONEDRIVE_DIR="$WORK/onedrive"
    mkdir -p "$PROJECTS_ROOT" "$ONEDRIVE_DIR"
    export ONEDRIVE_PROJECTS_BACKUP_DIR="$ONEDRIVE_DIR"
}

@test "clones a top-level repo that doesn't exist yet, skips if it does" {
    remote_dir="$WORK/remote/widget.git"
    make_bare_repo "$remote_dir"

    repo_target="$PROJECTS_ROOT/ENI/widget"
    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$repo_target"
    remotes:
      - name: "origin"
        url: "$remote_dir"
    ignored_files: []
folders: []
EOF

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [ -d "$repo_target/.git" ]

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping clone, already exists"* ]]
}

@test "--dry-run prints planned actions without cloning" {
    remote_dir="$WORK/remote/dryrun.git"
    make_bare_repo "$remote_dir"
    repo_target="$PROJECTS_ROOT/ENI/dryrun"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$repo_target"
    remotes:
      - name: "origin"
        url: "$remote_dir"
    ignored_files: []
folders: []
EOF

    run "$RESTORE" --dry-run "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: git clone"* ]]
    [ ! -d "$repo_target" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/restore-projects.bats`
Expected: FAIL with "No such file or directory" (`restore-projects.sh` doesn't exist yet)

- [ ] **Step 3: Write the implementation**

Create `restore-projects.sh`:

```bash
#!/usr/bin/env bash
#
# restore-projects.sh
#
# Run this MANUALLY on a NEW laptop, from the root of your dotfiles repo,
# once SSH keys and Bitwarden CLI are already set up (see
# .install-prerequisites.sh and private_dot_ssh/).
#
# Reads .chezmoidata/projects.yaml and:
#   1. git clones each top-level repo to its original path (skipped if the
#      path already exists)
#   2. restores each repo's gitignored "secret" files from Bitwarden
#      (items created by export-project-secrets.sh)
#   3. unzips each plain folder root from the OneDrive backup dir
#      (archives created by export-project-folders.sh)
#   4. git clones any nested repos back into place inside their folder root
#
# Usage:
#   ./restore-projects.sh [--dry-run] [PROJECTS_YAML]
#   PROJECTS_YAML defaults to .chezmoidata/projects.yaml
#   --dry-run prints planned actions without executing them
#   Backup dir comes from $ONEDRIVE_PROJECTS_BACKUP_DIR, falling back to
#   the onedriveProjectsBackupDir chezmoi data value.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DRY_RUN=0
PROJECTS_YAML=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) PROJECTS_YAML="$arg" ;;
    esac
done
PROJECTS_YAML="${PROJECTS_YAML:-$SCRIPT_DIR/.chezmoidata/projects.yaml}"

if [[ ! -f "$PROJECTS_YAML" ]]; then
    echo "Error: projects YAML not found at $PROJECTS_YAML" >&2
    exit 1
fi

ONEDRIVE_DIR="${ONEDRIVE_PROJECTS_BACKUP_DIR:-$(chezmoi data 2>/dev/null | jq -r '.onedriveProjectsBackupDir // empty')}"

FAILED_ITEMS=()

# Runs $* normally, or just echoes it under --dry-run.
run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: $*"
    else
        "$@"
    fi
}

# True (exit 0) if $1 is a path inside any folders[].path in PROJECTS_YAML.
is_nested_repo() {
    local repo_path="$1" folder_count="$2"
    for ((k = 0; k < folder_count; k++)); do
        local folder_path
        folder_path=$(yq ".folders[$k].path" "$PROJECTS_YAML")
        [[ "$repo_path" == "$folder_path"/* ]] && return 0
    done
    return 1
}

# Clones repos[idx] if its path doesn't exist yet.
restore_repo() {
    local idx="$1"
    local repo_path remote_url
    repo_path=$(yq ".repos[$idx].path" "$PROJECTS_YAML")
    remote_url=$(yq ".repos[$idx].remotes[0].url" "$PROJECTS_YAML")

    if [[ -d "$repo_path" ]]; then
        echo "Skipping clone, already exists: $repo_path"
    else
        run mkdir -p "$(dirname "$repo_path")"
        run git clone "$remote_url" "$repo_path"
    fi
}

projects_root=$(yq '.root' "$PROJECTS_YAML")
repo_count=$(yq '.repos | length' "$PROJECTS_YAML")
folder_count=$(yq '.folders | length' "$PROJECTS_YAML")

echo "== Restoring top-level repos =="
for ((i = 0; i < repo_count; i++)); do
    repo_path=$(yq ".repos[$i].path" "$PROJECTS_YAML")
    if is_nested_repo "$repo_path" "$folder_count"; then
        continue
    fi
    restore_repo "$i"
done
```

Run: `chmod +x restore-projects.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/restore-projects.bats`
Expected: PASS (2 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add restore-projects.sh tests/restore-projects.bats
git commit -m "$(cat <<'EOF'
Add restore-projects.sh: clone top-level repos with --dry-run

First slice of the new-laptop restore script: clones each curated
top-level repo if its path doesn't already exist, skipping repos
nested inside a folder root (handled once that root is unzipped).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Extend `restore-projects.sh` — restore secrets from Bitwarden

**Files:**
- Modify: `restore-projects.sh`
- Modify: `tests/restore-projects.bats`

**Interfaces:**
- Consumes: `repos[].ignored_files[]` from `projects.yaml`; `bw list items --search <name>` / `.notes` (base64), matching `add_secret_to_bw.sh`'s existing retrieval convention.
- Produces: `restore_secret <secret_name> <dest_path>` function; appends to the shared `FAILED_ITEMS` array on missing Bitwarden items; prints a `== Summary: N item(s) failed to restore ==` block at the end if `FAILED_ITEMS` is non-empty.

- [ ] **Step 1: Write the failing tests**

Add to `tests/restore-projects.bats` (after the existing `setup()` function, before the first `@test`):

```bash
setup_bw_stub() {
    BIN_DIR="$WORK/bin"
    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/bw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "list" && "$2" == "items" && "$3" == "--search" ]]; then
    query="$4"
    if [[ "$query" == "$FAKE_BW_ITEM_NAME" ]]; then
        printf '[{"name":"%s","notes":"%s"}]' "$FAKE_BW_ITEM_NAME" "$FAKE_BW_ITEM_NOTES"
    else
        echo "[]"
    fi
    exit 0
fi
echo "unhandled bw invocation: $*" >&2
exit 1
EOF
    chmod +x "$BIN_DIR/bw"
    export PATH="$BIN_DIR:$PATH"
}
```

Add these two `@test` blocks to the end of the file:

```bash
@test "restores a secret file from Bitwarden into the cloned repo" {
    setup_bw_stub
    remote_dir="$WORK/remote/withenv.git"
    make_bare_repo "$remote_dir"
    repo_target="$PROJECTS_ROOT/ENI/withenv"

    export FAKE_BW_ITEM_NAME="proj-secret:ENI/withenv:.env"
    export FAKE_BW_ITEM_NOTES="$(printf 'SECRET=1' | base64)"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$repo_target"
    remotes:
      - name: "origin"
        url: "$remote_dir"
    ignored_files:
      - ".env"
folders: []
EOF

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [ -f "$repo_target/.env" ]
    [ "$(cat "$repo_target/.env")" = "SECRET=1" ]
}

@test "reports a failure and continues when a Bitwarden item is missing" {
    setup_bw_stub
    remote_dir="$WORK/remote/noenv.git"
    make_bare_repo "$remote_dir"
    repo_target="$PROJECTS_ROOT/ENI/noenv"

    export FAKE_BW_ITEM_NAME="something-else"
    export FAKE_BW_ITEM_NOTES=""

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$repo_target"
    remotes:
      - name: "origin"
        url: "$remote_dir"
    ignored_files:
      - ".env"
folders: []
EOF

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: Bitwarden item not found"* ]]
    [[ "$output" == *"Summary: 1 item(s) failed to restore"* ]]
    [ ! -f "$repo_target/.env" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/restore-projects.bats`
Expected: The two new tests FAIL (no `.env` file is written since secret restoration doesn't exist yet); the two existing tests still PASS.

- [ ] **Step 3: Implement secret restoration**

In `restore-projects.sh`, add this function after `restore_repo`:

```bash
# Restores a single Bitwarden secret item to dest_path, or records a
# failure in FAILED_ITEMS if the item doesn't exist.
restore_secret() {
    local secret_name="$1" dest_path="$2"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY-RUN: restore secret $secret_name -> $dest_path"
        return 0
    fi
    if ! bw list items --search "$secret_name" \
        | jq -e --arg n "$secret_name" '[.[] | select(.name==$n)] | .[0]' >/dev/null; then
        echo "WARN: Bitwarden item not found for $secret_name (expected at $dest_path)" >&2
        FAILED_ITEMS+=("$secret_name")
        return 0
    fi
    mkdir -p "$(dirname "$dest_path")"
    bw list items --search "$secret_name" \
        | jq -r --arg n "$secret_name" '[.[] | select(.name==$n)] | .[0].notes' \
        | base64 -d > "$dest_path"
    echo "Restored secret $secret_name -> $dest_path"
}
```

Update `restore_repo` to also restore secrets, and pass `projects_root` in:

```bash
restore_repo() {
    local idx="$1"
    local repo_path remote_url repo_rel file_count
    repo_path=$(yq ".repos[$idx].path" "$PROJECTS_YAML")
    remote_url=$(yq ".repos[$idx].remotes[0].url" "$PROJECTS_YAML")
    repo_rel="${repo_path#"$projects_root"/}"

    if [[ -d "$repo_path" ]]; then
        echo "Skipping clone, already exists: $repo_path"
    else
        run mkdir -p "$(dirname "$repo_path")"
        run git clone "$remote_url" "$repo_path"
    fi

    file_count=$(yq ".repos[$idx].ignored_files | length" "$PROJECTS_YAML")
    for ((j = 0; j < file_count; j++)); do
        local file_rel secret_name
        file_rel=$(yq ".repos[$idx].ignored_files[$j]" "$PROJECTS_YAML")
        secret_name="proj-secret:${repo_rel}:${file_rel}"
        restore_secret "$secret_name" "$repo_path/$file_rel"
    done
}
```

Note `restore_repo` now references `projects_root`, which is declared with `local` in the main body below it — move the `projects_root=$(yq '.root' "$PROJECTS_YAML")` assignment (already present) so it runs *before* any call to `restore_repo` (it already does, since it's declared before the `for` loop that calls `restore_repo`; no change needed there, just confirm the ordering is preserved in the file: helper function definitions, then `projects_root=...`, then the repo loop).

At the end of the file (after the `for` loop that calls `restore_repo`), add the summary:

```bash

if [[ "${#FAILED_ITEMS[@]}" -gt 0 ]]; then
    echo "== Summary: ${#FAILED_ITEMS[@]} item(s) failed to restore =="
    printf '  %s\n' "${FAILED_ITEMS[@]}"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/restore-projects.bats`
Expected: PASS (4 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add restore-projects.sh tests/restore-projects.bats
git commit -m "$(cat <<'EOF'
Extend restore-projects.sh to restore secrets from Bitwarden

After cloning each repo, restores its gitignored secret files by name
(proj-secret:<repo>:<file>), and reports any missing Bitwarden items
in a summary at the end instead of aborting the run.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Extend `restore-projects.sh` — unzip folder roots and clone nested repos

**Files:**
- Modify: `restore-projects.sh`
- Modify: `tests/restore-projects.bats`

**Interfaces:**
- Consumes: `folders[].path`, `folders[].nested_repos[]` from `projects.yaml`; zip archives from `$ONEDRIVE_PROJECTS_BACKUP_DIR`.
- Produces: `find_repo_index_by_path <abs_path>` (echoes the matching index into `repos[]`, or returns non-zero); folder roots unzipped and their nested repos cloned+secret-restored via `restore_repo`.

- [ ] **Step 1: Write the failing test**

Add to the end of `tests/restore-projects.bats`:

```bash
@test "unzips a folder root and then clones its nested repo" {
    src_root="$WORK/src-fixture/fakejobfailurebundle"
    mkdir -p "$src_root"
    echo "hi" > "$src_root/README.md"

    nested_remote="$WORK/remote/vendor-widget.git"
    make_bare_repo "$nested_remote"

    (cd "$WORK/src-fixture" && zip -qr "$ONEDRIVE_DIR/EY-fakejobfailurebundle.zip" "fakejobfailurebundle")

    folder_target="$PROJECTS_ROOT/EY/fakejobfailurebundle"
    nested_target="$folder_target/vendor/widget"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$nested_target"
    remotes:
      - name: "origin"
        url: "$nested_remote"
    ignored_files: []
folders:
  - path: "$folder_target"
    nested_repos:
      - "vendor/widget"
EOF

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [ -f "$folder_target/README.md" ]
    [ -d "$nested_target/.git" ]
}

@test "warns and continues when a folder root's archive is missing" {
    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos: []
folders:
  - path: "$PROJECTS_ROOT/EY/nowhere"
    nested_repos: []
EOF

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: archive not found"* ]]
    [[ "$output" == *"Summary: 1 item(s) failed to restore"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/restore-projects.bats`
Expected: The two new tests FAIL (folder restoration doesn't exist yet — `README.md`/`.git` are never created, and no "archive not found" warning is printed); the four existing tests still PASS.

- [ ] **Step 3: Implement folder restoration**

In `restore-projects.sh`, add this function after `restore_secret`:

```bash
# Finds the index into repos[] whose path equals $1. Echoes the index and
# returns 0 on success; returns 1 if no match is found.
find_repo_index_by_path() {
    local target="$1" count="$2"
    for ((k = 0; k < count; k++)); do
        local p
        p=$(yq ".repos[$k].path" "$PROJECTS_YAML")
        if [[ "$p" == "$target" ]]; then
            echo "$k"
            return 0
        fi
    done
    return 1
}
```

Replace the final `echo "== Restoring top-level repos =="` loop block and the summary block at the end of the file with:

```bash
echo "== Restoring top-level repos =="
for ((i = 0; i < repo_count; i++)); do
    repo_path=$(yq ".repos[$i].path" "$PROJECTS_YAML")
    if is_nested_repo "$repo_path" "$folder_count"; then
        continue
    fi
    restore_repo "$i"
done

echo "== Restoring folder roots =="
for ((i = 0; i < folder_count; i++)); do
    folder_path=$(yq ".folders[$i].path" "$PROJECTS_YAML")
    parent_dir="$(dirname "$folder_path")"
    archive_name="$(echo "${folder_path#"$projects_root"/}" | tr '/' '-').zip"
    archive_path="$ONEDRIVE_DIR/$archive_name"

    if [[ -d "$folder_path" ]]; then
        echo "Skipping unzip, already exists: $folder_path"
    elif [[ ! -f "$archive_path" ]]; then
        echo "WARN: archive not found for $folder_path (expected $archive_path)" >&2
        FAILED_ITEMS+=("$archive_path")
    else
        run mkdir -p "$parent_dir"
        run unzip -q "$archive_path" -d "$parent_dir"
    fi

    nested_count=$(yq ".folders[$i].nested_repos | length" "$PROJECTS_YAML")
    for ((j = 0; j < nested_count; j++)); do
        nested_rel=$(yq ".folders[$i].nested_repos[$j]" "$PROJECTS_YAML")
        nested_path="$folder_path/$nested_rel"
        idx=$(find_repo_index_by_path "$nested_path" "$repo_count") || {
            echo "WARN: no repos[] entry found for nested repo $nested_path" >&2
            FAILED_ITEMS+=("$nested_path")
            continue
        }
        restore_repo "$idx"
    done
done

if [[ "${#FAILED_ITEMS[@]}" -gt 0 ]]; then
    echo "== Summary: ${#FAILED_ITEMS[@]} item(s) failed to restore =="
    printf '  %s\n' "${FAILED_ITEMS[@]}"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/restore-projects.bats`
Expected: PASS (6 tests, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add restore-projects.sh tests/restore-projects.bats
git commit -m "$(cat <<'EOF'
Extend restore-projects.sh to unzip folder roots and clone nested repos

Folder roots are unzipped from the OneDrive backup dir after their
top-level repos are restored, then any nested repos recorded on the
folder entry are cloned (and their own secrets restored) into place.
Missing archives are reported in the failure summary instead of
aborting the run.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Add curated `projects.yaml` scaffold and finalize docs

**Files:**
- Create: `.chezmoidata/projects.yaml`
- Modify: `scan_repos.sh` (header comment only — document the roots + nested_repos schema)

**Interfaces:**
- Produces: an empty, valid `.chezmoidata/projects.yaml` scaffold matching the schema all prior tasks depend on, ready for you to fill in by running `scan_repos.sh` and pruning its output into this file.

- [ ] **Step 1: Create the scaffold file**

Create `.chezmoidata/projects.yaml`:

```yaml
# Curated subset of `$HOME/Projects` to back up and restore on a new
# laptop. Produced by hand: run `./scan_repos.sh "$HOME/Projects"`, copy
# its output here, and delete entries you don't want to carry forward
# (also prune each repo's ignored_files down to actual secrets worth
# restoring, e.g. drop cache/lock files).
#
# Schema (matches scan_repos.sh's output):
#   root: absolute path scan_repos.sh was run against
#   repos[].path: absolute path to a git repo
#   repos[].remotes[].name / .url: git remotes
#   repos[].ignored_files[]: gitignored files to restore via Bitwarden
#     (proj-secret:<repo-path-relative-to-root>:<file-relative-path>)
#   folders[].path: absolute path to a plain (non-git) project root
#   folders[].nested_repos[]: paths of git repos found inside that root,
#     relative to it — excluded from its zip archive, restored via clone
root: ""
repos: []
folders: []
```

- [ ] **Step 2: Update `scan_repos.sh`'s header comment to describe the new schema**

Replace the header comment block at the top of `scan_repos.sh`:

```bash
# scan_repos.sh — recursively find git repos under a root directory and report
# their remotes, dirty status, and ignored files (excluding common build artifacts).
# Also flags plain (non-repo) folders that directly contain files.
# Output is YAML, with repos and folders reported as two separate lists.
#
# Usage: ./scan_repos.sh [ROOT_DIR] [MAX_JOBS]
#   ROOT_DIR  defaults to current directory  (default: .)
#   MAX_JOBS  parallel workers at depth-1    (default: 8)
```

with:

```bash
# scan_repos.sh — recursively find git repos under a root directory and report
# their remotes, dirty status, and ignored files (excluding common build artifacts).
# Also reports plain (non-repo) folder roots — the shallowest directory in a
# subtree that directly contains files — along with any git repos nested
# inside that root (as nested_repos, relative to the root), so downstream
# backup tooling can exclude nested repos from a root's zip archive.
# Output is YAML, with repos and folders reported as two separate lists.
#
# See docs/superpowers/specs/2026-07-10-projects-backup-restore-design.md
# for how this feeds .chezmoidata/projects.yaml, export-project-secrets.sh,
# export-project-folders.sh, and restore-projects.sh.
#
# Usage: ./scan_repos.sh [ROOT_DIR] [MAX_JOBS]
#   ROOT_DIR  defaults to current directory  (default: .)
#   MAX_JOBS  parallel workers at depth-1    (default: 8)
```

- [ ] **Step 3: Run the full test suite as a final regression check**

Run: `bats tests/`
Expected: PASS (all tests across `scan_repos.bats`, `export-project-secrets.bats`, `export-project-folders.bats`, `restore-projects.bats`, 0 failures)

- [ ] **Step 4: Commit**

```bash
git add .chezmoidata/projects.yaml scan_repos.sh
git commit -m "$(cat <<'EOF'
Add projects.yaml scaffold and document the roots + nested_repos schema

Empty starting point for curating the real Projects backup list by
hand, per the design doc; scan_repos.sh's header now documents how its
output feeds into the export/restore scripts.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

**This task is manual, ongoing work for you afterward, not something to automate:** actually populating `.chezmoidata/projects.yaml` with your real repos/folders (running `scan_repos.sh "$HOME/Projects"`, pruning it) and running `export-project-secrets.sh` / `export-project-folders.sh` against your real `$HOME/Projects` tree.
