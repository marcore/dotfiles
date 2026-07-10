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
