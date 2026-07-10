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
