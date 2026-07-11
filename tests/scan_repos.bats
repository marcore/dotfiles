#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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

    run --separate-stderr "$SCAN_REPOS" "$PROJECTS_DIR" 2
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

    run --separate-stderr "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    nested=$(yq '.folders[0].nested_repos[0]' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$nested" = "vendor/widget" ]

    repo_path=$(yq '.repos[0].path' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$repo_path" = "$PROJECTS_DIR/EY/fakejobfailurebundle/vendor/widget" ]
}

@test "folder root with no nested repos reports nested_repos as an empty list" {
    make_plain_dir_with_file "$PROJECTS_DIR/EY/plainproj" "notes.txt"

    run --separate-stderr "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    nested_type=$(yq '.folders[0].nested_repos | type' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$nested_type" = "!!seq" ]
    nested_len=$(yq '.folders[0].nested_repos | length' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$nested_len" -eq 0 ]
}

@test "existing repo detection (remotes, clean status) is unchanged" {
    make_git_repo "$PROJECTS_DIR/ENI/cf-extension-demo" "git@github.com:marcore/cf-extension-demo.git"

    run --separate-stderr "$SCAN_REPOS" "$PROJECTS_DIR" 2
    [ "$status" -eq 0 ]
    echo "$output" > "$BATS_TEST_TMPDIR/out.yaml"

    remote_name=$(yq '.repos[0].remotes[0].name' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$remote_name" = "origin" ]
    remote_url=$(yq '.repos[0].remotes[0].url' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$remote_url" = "git@github.com:marcore/cf-extension-demo.git" ]
    status_val=$(yq '.repos[0].status' "$BATS_TEST_TMPDIR/out.yaml")
    [ "$status_val" = "clean" ]
}
