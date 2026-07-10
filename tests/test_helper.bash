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
