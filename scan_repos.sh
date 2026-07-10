#!/usr/bin/env bash

# scan_repos.sh — recursively find git repos under a root directory and report
# their remotes, dirty status, and ignored files (excluding common build artifacts).
# Also flags plain (non-repo) folders that directly contain files.
# Output is YAML, with repos and folders reported as two separate lists.
#
# Usage: ./scan_repos.sh [ROOT_DIR] [MAX_JOBS]
#   ROOT_DIR  defaults to current directory  (default: .)
#   MAX_JOBS  parallel workers at depth-1    (default: 8)

set -uo pipefail

ROOT_DIR="${1:-.}"
MAX_JOBS="${2:-8}"
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
# Core scanner (called in each worker subshell). Appends YAML list items to
# repo_out (list of repo maps) and folder_out (list of plain path scalars).
# ──────────────────────────────────────────────────────────────────────────────

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

# ──────────────────────────────────────────────────────────────────────────────
# Worker: scan one depth-1 subtree, write output to numbered temp files so
# results can be printed in stable order after all workers finish.
# ──────────────────────────────────────────────────────────────────────────────

worker() {
    local idx="$1"
    local dir="$2"
    local repo_out="$WORK_DIR/$(printf '%06d' "$idx").repos"
    local folder_out="$WORK_DIR/$(printf '%06d' "$idx").folders"
    : > "$repo_out"
    : > "$folder_out"
    scan_directory "$dir" "$repo_out" "$folder_out" 2>/dev/null
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

# Fast path: root itself is already a repo — no parallelism needed
if [[ -d "$ROOT_DIR/.git" ]]; then
    scan_directory "$ROOT_DIR" "$WORK_DIR/000000.repos" "$WORK_DIR/000000.folders"
    print_yaml_list "repos" "repos"
    print_yaml_list "folders" "folders"
    echo "summary:"
    echo "  scanned_top_level_dirs: 0"
    exit 0
fi

# Collect first-level subdirectories (the unit of parallelism)
declare -a SUBDIRS=()
while IFS= read -r -d '' subdir; do
    name="$(basename "$subdir")"
    should_skip "$name" && continue
    SUBDIRS+=("$subdir")
done < <(find "$ROOT_DIR" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)

total="${#SUBDIRS[@]}"

if [[ "$total" -eq 0 ]]; then
    echo "repos: []"
    echo "folders: []"
    echo "summary:"
    echo "  scanned_top_level_dirs: 0"
    exit 0
fi

# Spawn workers, throttling to MAX_JOBS concurrent jobs.
# Uses `jobs -rp` for bash 3.x compatibility (no `wait -n` needed).
idx=0
for subdir in "${SUBDIRS[@]}"; do
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        sleep 0.05
    done
    worker "$idx" "$subdir" &
    idx=$((idx + 1))
done

# Wait for all workers to finish
wait

print_yaml_list "repos" "repos"
print_yaml_list "folders" "folders"

echo "summary:"
echo "  scanned_top_level_dirs: $idx"
