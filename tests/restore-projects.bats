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
    perm=$(stat -f "%Lp" "$repo_target/.env" 2>/dev/null || stat -c "%a" "$repo_target/.env")
    [ "$perm" = "600" ]
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

@test "--dry-run previews nested repo clone for a folder root without creating anything" {
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

    run "$RESTORE" --dry-run "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: git clone"* ]]
    [ ! -d "$folder_target" ]
    [ ! -d "$nested_target" ]
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

@test "reports a failure and continues to the next repo when git clone fails" {
    bad_remote="$WORK/remote/does-not-exist.git"
    good_remote_dir="$WORK/remote/good.git"
    make_bare_repo "$good_remote_dir"

    bad_target="$PROJECTS_ROOT/ENI/bad"
    good_target="$PROJECTS_ROOT/ENI/good"

    cat > "$WORK/projects.yaml" <<EOF
root: "$PROJECTS_ROOT"
repos:
  - path: "$bad_target"
    remotes:
      - name: "origin"
        url: "$bad_remote"
    ignored_files: []
  - path: "$good_target"
    remotes:
      - name: "origin"
        url: "$good_remote_dir"
    ignored_files: []
folders: []
EOF

    run "$RESTORE" "$WORK/projects.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN: git clone failed for $bad_target"* ]]
    [[ "$output" == *"Summary: 1 item(s) failed to restore"* ]]
    [ ! -d "$bad_target" ]
    [ -d "$good_target/.git" ]
}

@test "warns and continues when a folder root's archive is corrupt, and skips its nested repos" {
    folder_target="$PROJECTS_ROOT/EY/corruptbundle"
    archive_path="$ONEDRIVE_DIR/EY-corruptbundle.zip"
    echo "not a real zip" > "$archive_path"

    nested_remote="$WORK/remote/vendor-widget2.git"
    make_bare_repo "$nested_remote"
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
    [[ "$output" == *"WARN: unzip failed for $folder_target"* ]]
    [[ "$output" == *"Summary: 1 item(s) failed to restore"* ]]
    [ ! -d "$folder_target" ]
    [ ! -d "$nested_target" ]
}
