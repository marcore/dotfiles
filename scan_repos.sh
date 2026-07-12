#!/usr/bin/env bash

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
# Usage: ./scan_repos.sh [ROOT_DIR] [MAX_JOBS] [MAX_DEPTH]
#   ROOT_DIR   defaults to current directory  (default: .)
#   MAX_JOBS   parallel workers                (default: 8)
#   MAX_DEPTH  discovery depth cutoff, counted from ROOT_DIR (top-level
#              subdirs = depth 1); 0 = unlimited (default: 0). Past the
#              cutoff, a directory not already inside a folder root is
#              reported as a folder itself instead of recursing further —
#              on the assumption git repos don't live that deep. Repos
#              actually found past the cutoff are not lost: they still show
#              up under that folder's nested_repos, just without their own
#              full repos: entry (remotes/status/ignored_files).
#
# Runs in two phases, each throttled to MAX_JOBS concurrent jobs:
#   1. discover — walk depth-1 subtrees in parallel to find every repo and
#      folder root at any depth (cheap: no git calls, just find/stat).
#   2. process  — run the actual git commands (remotes, status, ignored
#      files) and nested-repo search for every discovered repo/folder in
#      parallel, flattened across the whole tree. This is what makes
#      parallelism apply beyond depth-1: a top-level dir with 50 repos no
#      longer serializes behind a single worker while others sit idle.

set -uo pipefail

ROOT_DIR="${1:-.}"
MAX_JOBS="${2:-8}"
MAX_DEPTH="${3:-7}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

SKIP_DIRS=(node_modules target dist build .git aem-sdk AEM6.5)
IGNORED_DIR_PATTERN='(\.git|node_modules|target|dist|build|\.DS_Store|\.wrangler|playwright-report|test-results|\.classpath|\.settings|\.project)(/.*)?$'
IGNORED_FILE_PATTERN='^(\.DS_Store)$'

# Temp dir for buffered worker output; cleaned up on exit
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

should_skip() {
    local name="$1"
    [[ "$name" == .* ]] && return 0
    for skip in "${SKIP_DIRS[@]}"; do
        [[ "$name" == "$skip" ]] && return 0
    done
    return 1
}

# Emit a YAML double-quoted scalar for an arbitrary string.
yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

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

# ──────────────────────────────────────────────────────────────────────────────
# Phase 1 — discovery (called in each depth-1 worker subshell). No git calls:
# just walks the tree and appends plain paths (one per line) to repo_list_out
# and folder_list_out, in stable DFS order.
# ──────────────────────────────────────────────────────────────────────────────

discover_directory() {
    local dir="$1" repo_list_out="$2" folder_list_out="$3" in_root="${4:-0}" depth="${5:-1}"

    # Heartbeat: this counter is a plain variable, not passed as an arg, so
    # it's shared (via bash dynamic scoping) across this whole recursive
    # call tree within one discover_worker subshell — no locking needed
    # since each worker has its own copy. Prints periodically so a deep/wide
    # subtree doesn't go silent for minutes with no visible progress.
    DISCOVER_VISITED=$((DISCOVER_VISITED + 1))
    if (( DISCOVER_VISITED % 200 == 0 )); then
        printf '[discover] ...still walking (%d dirs visited so far): %s\n' "$DISCOVER_VISITED" "$dir" >&2
    fi

    if [[ -d "$dir/.git" ]]; then
        echo "$dir" >> "$repo_list_out"
        printf '[discover] repo: %s\n' "$dir" >&2
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
            echo "$dir" >> "$folder_list_out"
            printf '[discover] folder: %s\n' "$dir" >&2
            in_root=1
        fi
    fi

    # Depth cutoff: stop descending and, unless already folded into a
    # folder root above, report this directory as one instead — on the
    # assumption git repos don't live this deep. Repos actually found
    # deeper are still picked up via find_nested_repos on that folder.
    if [[ "$MAX_DEPTH" -gt 0 && "$depth" -ge "$MAX_DEPTH" ]]; then
        if [[ "$in_root" -eq 0 ]]; then
            echo "$dir" >> "$folder_list_out"
            printf '[discover] folder (max depth %d reached): %s\n' "$MAX_DEPTH" "$dir" >&2
        fi
        return
    fi

    while IFS= read -r -d '' subdir; do
        local name
        name="$(basename "$subdir")"
        should_skip "$name" && continue
        discover_directory "$subdir" "$repo_list_out" "$folder_list_out" "$in_root" "$((depth + 1))"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)
}

# Discovery worker: walk one depth-1 subtree, write path lists to numbered
# temp files so they can be flattened in stable order once all finish.
discover_worker() {
    local idx="$1"
    local dir="$2"
    local repo_list_out="$WORK_DIR/$(printf '%06d' "$idx").repolist"
    local folder_list_out="$WORK_DIR/$(printf '%06d' "$idx").folderlist"
    local DISCOVER_VISITED=0
    : > "$repo_list_out"
    : > "$folder_list_out"
    discover_directory "$dir" "$repo_list_out" "$folder_list_out"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 2 — processing (called in each per-item worker subshell). Runs the
# actual git commands / nested-repo search for a single already-discovered
# repo or folder root, writing its YAML block to a numbered temp file.
# ──────────────────────────────────────────────────────────────────────────────

process_repo() {
    local idx="$1" dir="$2"
    local out="$WORK_DIR/$(printf '%06d' "$idx").repos"
    {
        echo "  - path: $(yaml_quote "$dir")"

        local remotes_v
        remotes_v=$(git -C "$dir" remote -v 2>/dev/null | awk '$3 == "(fetch)"' || true)
        if [[ -n "$remotes_v" ]]; then
            echo "    remotes:"
            while IFS=$'\t ' read -r name url _; do
                echo "      - name: $(yaml_quote "$name")"
                echo "        url: $(yaml_quote "$url")"
            done <<< "$remotes_v"
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
        ignored=$(git -C "$dir" ls-files --others --directory --ignored --exclude-standard 2>/dev/null \
            | grep -vE "$IGNORED_DIR_PATTERN" || true)
        if [[ -n "$ignored" ]]; then
            echo "    ignored_files:"
            while IFS= read -r line; do
                echo "      - $(yaml_quote "$line")"
            done <<< "$ignored"
        else
            echo "    ignored_files: []"
        fi
    } 2>/dev/null >> "$out"
}

process_folder() {
    local idx="$1" dir="$2"
    local out="$WORK_DIR/$(printf '%06d' "$idx").folders"
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
    } 2>/dev/null >> "$out"
}

# Print a YAML list from the concatenation of $WORK_DIR/*.<ext>, or "key: []"
# if all such files are empty.
print_yaml_list() {
    local key="$1" ext="$2"
    shopt -s nullglob
    local files=("$WORK_DIR"/*."$ext")
    shopt -u nullglob
    if [[ "${#files[@]}" -eq 0 ]] || ! grep -qs . "${files[@]}" 2>/dev/null; then
        echo "$key: []"
    else
        echo "$key:"
        cat "${files[@]}" 2>/dev/null
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────

echo "root: $(yaml_quote "$ROOT_DIR")"
echo "max_jobs: $MAX_JOBS"

# Uses `jobs -rp` for bash 3.x compatibility (no `wait -n` needed).
# Progress goes to stderr so stdout stays clean YAML.

declare -a REPO_LIST=()
declare -a FOLDER_LIST=()
scanned_top_level_dirs=0

if [[ -d "$ROOT_DIR/.git" ]]; then
    # Fast path: root itself is already a repo — no discovery needed.
    REPO_LIST=("$ROOT_DIR")
else
    # Collect first-level subdirectories (the unit of discovery parallelism)
    declare -a SUBDIRS=()
    while IFS= read -r -d '' subdir; do
        name="$(basename "$subdir")"
        should_skip "$name" && continue
        SUBDIRS+=("$subdir")
    done < <(find "$ROOT_DIR" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)

    scanned_top_level_dirs="${#SUBDIRS[@]}"

    if [[ "$scanned_top_level_dirs" -gt 0 ]]; then
        # Phase 1: discover repos/folders in parallel across depth-1 subtrees.
        idx=0
        for subdir in "${SUBDIRS[@]}"; do
            while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
                sleep 0.05
            done
            printf '[discover %d/%d] %s\n' "$((idx + 1))" "$scanned_top_level_dirs" "$subdir" >&2
            discover_worker "$idx" "$subdir" &
            idx=$((idx + 1))
        done
        wait

        # Flatten discovery results into two ordered arrays: depth-1 dir
        # order (matching SUBDIRS), then DFS order within each subtree.
        shopt -s nullglob
        repolists=("$WORK_DIR"/*.repolist)
        folderlists=("$WORK_DIR"/*.folderlist)
        shopt -u nullglob
        if [[ "${#repolists[@]}" -gt 0 ]]; then
            while IFS= read -r line; do
                REPO_LIST+=("$line")
            done < <(cat "${repolists[@]}" 2>/dev/null)
        fi
        if [[ "${#folderlists[@]}" -gt 0 ]]; then
            while IFS= read -r line; do
                FOLDER_LIST+=("$line")
            done < <(cat "${folderlists[@]}" 2>/dev/null)
        fi
    fi
fi

# Phase 2: process every discovered repo/folder in parallel, flattened
# across the whole tree — this is where parallelism now applies beyond
# depth-1, since the item count no longer depends on top-level dir count.
total_repos="${#REPO_LIST[@]}"
total_folders="${#FOLDER_LIST[@]}"

idx=0
for dir in "${REPO_LIST[@]+"${REPO_LIST[@]}"}"; do
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        sleep 0.05
    done
    printf '[repo %d/%d] %s\n' "$((idx + 1))" "$total_repos" "$dir" >&2
    process_repo "$idx" "$dir" &
    idx=$((idx + 1))
done

idx=0
for dir in "${FOLDER_LIST[@]+"${FOLDER_LIST[@]}"}"; do
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        sleep 0.05
    done
    printf '[folder %d/%d] %s\n' "$((idx + 1))" "$total_folders" "$dir" >&2
    process_folder "$idx" "$dir" &
    idx=$((idx + 1))
done

wait

print_yaml_list "repos" "repos"
print_yaml_list "folders" "folders"

echo "summary:"
echo "  scanned_top_level_dirs: $scanned_top_level_dirs"
