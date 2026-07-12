# Projects folder backup & restore — design

## Problem

`$HOME/Projects` holds development work: some directories are git repos (cloned
from a remote), some are plain folders with files but no git. Neither is
currently reproducible on a new laptop via chezmoi. Additionally, git repos
often contain gitignored files (`.env`, credential files, etc.) that hold
secrets needed to actually run the project after cloning.

`scan_repos.sh` already exists and walks `$HOME/Projects`, emitting a YAML
inventory of repos (path, remotes, dirty status, ignored files) and plain
folders (paths that directly contain files). This design builds the
curation, export, and restore mechanism on top of that inventory.

## Goals

- Recreate the important parts of `$HOME/Projects` on a new laptop:
  - git repos: re-cloned from their recorded remote.
  - plain (non-git) folders: their actual file contents restored from a zip
    archive.
  - gitignored secret files inside repos (`.env`, etc.): restored from
    Bitwarden into the freshly cloned repo.
- Let the user curate *which* repos/folders are worth backing up — not
  everything under `Projects` needs to survive a laptop migration.
- Reuse existing patterns in this repo (`add_secret_to_bw.sh` for Bitwarden
  secrets, `export-*.sh` / manual restore scripts for snapshot-based data)
  rather than inventing new mechanisms.

## Non-goals

- Automatic, unattended restore during `chezmoi apply`. Cloning many repos
  and unzipping large archives are manual, deliberate steps.
- Backing up build artifacts or caches (`node_modules`, `.parcel-cache`,
  etc.) — these are excluded by `scan_repos.sh` already, and the curation
  step further prunes non-secret ignored files.

## Architecture / data flow

```
OLD LAPTOP                                          NEW LAPTOP
─────────────────────────────────────────────────────────────────
scan_repos.sh (reworked)
  → full inventory (scratch, not committed)
        │
        │  manual prune by hand
        ▼
.chezmoidata/projects.yaml  ──► export-projects-yaml.sh ──► Bitwarden items
  (repos + folder roots,          (chunked secure notes,     ("dotfiles:projects.yaml"
   NOT committed --                 like proj-secret items)   + "...#0", "...#1", ...)
   real file is skip-worktree)                                          │
        │                                              fetch-projects-yaml.sh
        │                                                (pulls the chunks back
        │                                                 down into
        │                                                 .chezmoidata/projects.yaml,
        │                                                 marks it skip-worktree)
        │                                                            │
        │                                                            ▼
        ├─► export-project-secrets.sh                  .chezmoidata/projects.yaml
        │     (repo ignored_files → Bitwarden,            (source of truth on new machine)
        │      via add_secret_to_bw.sh --chunked)                    │
        │                                                          ▼
        └─► export-project-folders.sh                  restore-projects.sh
              (zip folder roots, excluding                 1. git clone each repo
               nested_repos, → OneDrive)                    2. pull secrets from Bitwarden
                    │                                          into each repo's ignored files
                    ▼                                       3. unzip each folder root from
              OneDrive shared folder ──── synced ─────►        OneDrive
                                                             4. git clone each nested_repo
                                                                inside its unzipped root
```

Cloning and unzipping are run manually on the new laptop, not wired into an
automatic `chezmoi apply` hook.

`projects.yaml` itself isn't committed to this public repo: the curated data
names private/internal repos and org structure that don't belong in a public
dotfiles repo (unlike the OneDrive folder archives, which are already a
private channel, `git@github.com` history is public and permanent). Only an
empty placeholder is tracked; the real file is round-tripped through
Bitwarden -- the same private, cross-machine channel already used for
per-repo secrets -- and kept out of `git status`/`git diff` locally via
`git update-index --skip-worktree`.

## Components

### 1. `scan_repos.sh` (reworked)

Repo detection is unchanged: when a directory contains `.git`, it's recorded
as a repo entry (path, remotes, dirty status, ignored files) and the scanner
does not recurse into it.

Folder detection changes from "flag every directory that directly contains
files" to **project roots**:

- A folder becomes a *root* the first time the scanner finds a non-repo
  directory that directly contains files (existing `has_files` check).
- Once a root is found, the scanner does not emit separate entries for
  directories nested inside it — those are covered by the root's own
  eventual zip backup.
- The scanner *does* continue recursing beneath a root, but only to find
  git repos nested inside it. Each such nested repo is recorded as a
  `nested_repos` entry (path relative to the root) on the root's YAML node,
  so downstream tooling knows to exclude it from the root's zip (it's
  restored separately via clone) and to clone it back into place after
  unzipping.

Reworked folder output shape:

```yaml
folders:
  - path: "/Users/marcore/Projects/EY/fakejobfailurebundle"
    nested_repos:
      - "vendor/some-submodule-like-thing"
```

(`nested_repos: []` when none are found.)

The `repos:` list's schema (path, remotes, status, ignored_files) is
unchanged.

### 2. `.chezmoidata/projects.yaml` (curated, NOT committed)

Produced by hand: run `scan_repos.sh`, copy its output, and prune entries
you don't want to carry forward. Same schema as the scan output. Pruning
also applies to each repo's `ignored_files` — drop cache/lock files
(`.parcel-cache/*`, etc.) and keep only files that are actual secrets worth
restoring (`.env`, `.aws.tmp.creds.json`, ...).

Only an empty placeholder (documenting the schema in a header comment) is
committed to the repo. The real, curated file lives locally, marked
git-skip-worktree (see `export-projects-yaml.sh` / `fetch-projects-yaml.sh`
below) so edits to it never show up as a pending change to commit.

### 2a. `export-projects-yaml.sh` / `fetch-projects-yaml.sh` (new, manual)

Round-trip `.chezmoidata/projects.yaml` itself through Bitwarden, **chunked
across multiple secure-note items** (same convention as `proj-secret:...`
items) rather than a single item's `notes` field, which caps out at 10000
encrypted characters -- far smaller than a real curated `projects.yaml`.
(Bitwarden attachments would avoid the chunking entirely, but they require
a Premium subscription, which can't be assumed here.) The layout is an
"index" item (`dotfiles:projects.yaml`, `notes: "CHUNKED:<count>"`) plus
`count` chunk items (`dotfiles:projects.yaml#0`, `#1`, ...), each holding
one slice of the base64-encoded file in its own `notes` field:

- `export-projects-yaml.sh`, run on whichever laptop just re-curated the
  file, is a thin wrapper around `add_secret_to_bw.sh ... --chunked`:
  creates the index + chunk items if missing, or replaces their content
  (and deletes now-orphaned trailing chunks) if present.
- `fetch-projects-yaml.sh`, run on a new laptop before `restore-projects.sh`,
  reads the index item's chunk count, pulls each chunk item's `notes` in
  order, concatenates and base64-decodes them, and writes the result to
  `.chezmoidata/projects.yaml` (refusing to overwrite an already-curated
  local file unless `--force`), then marks the file git-skip-worktree.

### 3. `export-project-secrets.sh` (new, manual, run on old laptop)

Reads `.chezmoidata/projects.yaml`. For every repo, for every entry in its
(pruned) `ignored_files`, computes a Bitwarden item name:

```
proj-secret:<repo-path-relative-to-Projects-root>:<file-relative-path>
```

e.g. `proj-secret:ENI/cf-extension-demo:.env`

and calls the existing `add_secret_to_bw.sh <name> <repo>/<file>
--chunked`, using the same Bitwarden folder as SSH key secrets.
`--chunked` splits the file's base64 content across an index item plus
`<name>#0`, `#1`, ... chunk items rather than a single item's `notes`
field (which caps at 10000 encrypted characters -- too small for most real
secret files, and the original cause of a real "Notes exceeds the maximum
encrypted value length" failure; Bitwarden attachments were tried first
but require a Premium subscription) and always replaces the existing
content, so re-running this after a project secret's content changes (a
rotated token, etc.) refreshes it instead of leaving it stale. This is a
different mode from plain `--update` (single-item notes), which
`add_secret_to_bw.sh` still supports for small, stable secrets; without
either flag it defaults to create-once-and-skip, which is what manual SSH
key secret creation still relies on.

### 3a. `add_repo_auth_to_bw.sh` (new, manual, run on old laptop)

Some repos can't use SSH -- Adobe Cloud Manager git issues a distinct HTTPS
username/password (per-repo, not shared -- see `dot_gitconfig.tmpl`'s
`[credential "git.cloudmanager.adobe.com"] useHttpPath = true`) instead of an
SSH remote. For these, mark the `projects.yaml` entry with `auth: https`,
then run:

```
./add_repo_auth_to_bw.sh <repo-path-relative-to-Projects-root>
```

which prompts interactively for username and password (hidden input, never
passed as arguments) and creates or updates a Bitwarden **login** item (not
a secure note, since this is a real username/password pair) named
`repo-auth:<repo-path-relative-to-Projects-root>`.

Repos without `auth: https` clone via plain SSH. Some rely on
`~/.ssh/config` (`private_dot_ssh/private_config`) host aliases (e.g.
`adobe-ssh.github.com`) to pick the right identity; others rely on
whichever key is currently loaded in the ssh-agent (the `gitmre`/
`gitmarcore` `dot_zshrc` aliases: `ssh-add -D && ssh-add ~/.ssh/<key>`),
since GitHub doesn't require a distinct hostname per account. For the
latter, mark the repo's `projects.yaml` entry with `ssh_identity:
<key-filename>` (see component 5) so `restore-projects.sh` can replicate
the same agent switch non-interactively before cloning.

### 4. `export-project-folders.sh` (new, manual, run on old laptop)

Reads `.chezmoidata/projects.yaml`. For each folder root, zips it to
`$onedriveProjectsBackupDir/<sanitized-root-name>.zip`, passing `-x`
exclusions for each of its `nested_repos` paths so nested repos are not
duplicated into the archive.

### 5. `restore-projects.sh` (new, generated from `projects.yaml`, run
   manually on new laptop)

For each repo in `projects.yaml`:
- if the target path doesn't already exist, clone it:
  - `auth: https` repos look up username/password from the
    `repo-auth:<repo-rel-path>` Bitwarden login item and clone using a
    short-lived `GIT_ASKPASS` script (the password never touches
    `.git/config`'s remote URL or shell argv; the username is
    percent-encoded via `jq`'s `@uri` before being embedded in the URL,
    since Cloud Manager usernames are often email addresses containing
    `@`);
  - SSH repos with an `ssh_identity: <key-filename>` entry get that key
    loaded into the ssh-agent first (`ssh-add -D && ssh-add
    ~/.ssh/<key-filename>`), skipped when it's already the identity loaded
    by the previous repo in this run (`CURRENT_SSH_IDENTITY`), so a run of
    several same-identity repos in a row doesn't reset the agent (and
    potentially re-prompt for a passphrase) between each one;
  - all other repos clone via plain `git clone` over SSH as-is.
- for each of its `ignored_files`, look up the matching
  `proj-secret:...` Bitwarden item, decode, and write it to the
  corresponding path inside the cloned repo.

For each folder root in `projects.yaml`:
- unzip its archive from `$onedriveProjectsBackupDir` into place;
- for each of its `nested_repos`, `git clone` into the corresponding
  relative path inside the just-restored root.

Supports a `--dry-run` flag that prints the planned clone/restore/unzip
actions without executing them.

### 6. Config: `onedriveProjectsBackupDir`

Added as a prompted/stored value in `.chezmoi.toml.tmpl`, same pattern as
the existing `isWorkComputer` prompt. Both export and restore scripts read
this value (via `chezmoi data`) to locate the OneDrive shared folder for zip
archives.

## Error handling

- `restore-projects.sh` skips (does not fail) repos whose target path
  already exists — safe to re-run.
- Secret restore fails loudly per-file when a Bitwarden item is missing
  (not yet exported, or name mismatch), but continues processing the rest;
  a summary of failures is printed at the end of the run.
- Folder restore checks that each expected archive exists in
  `$onedriveProjectsBackupDir` before unzipping; if OneDrive hasn't finished
  syncing, it reports the missing archives rather than partially unzipping.

## Testing / verification

- `restore-projects.sh --dry-run` lets a curated `projects.yaml` be sanity
  checked before committing to clones/unzips on a fresh machine.
- `export-project-secrets.sh` and `export-projects-yaml.sh` both call
  `add_secret_to_bw.sh ... --chunked`, so re-running exports after adding
  new repos or changing secret content is safe: existing chunk items get
  replaced (and orphaned trailing chunks deleted) rather than duplicated or
  left stale.
- Verified the chunk split/reassembly logic directly: base64-encoded a
  ~13.7KB random file, split it into 5000-character chunks, reassembled and
  base64-decoded the result, and confirmed an exact byte-for-byte match
  with the original file.
