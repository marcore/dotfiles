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
