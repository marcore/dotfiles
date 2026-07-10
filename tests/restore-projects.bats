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
