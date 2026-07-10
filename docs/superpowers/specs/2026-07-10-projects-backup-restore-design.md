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
.chezmoidata/projects.yaml   ──── committed ────►  .chezmoidata/projects.yaml
  (repos + folder roots)                             (source of truth on new machine)
        │                                                    │
        ├─► export-project-secrets.sh                        │
        │     (repo ignored_files → Bitwarden,                │
        │      via add_secret_to_bw.sh)                       │
        │                                                     ▼
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

### 2. `.chezmoidata/projects.yaml` (curated, committed)

Produced by hand: run `scan_repos.sh`, copy its output, and prune entries
you don't want to carry forward. Same schema as the scan output. Pruning
also applies to each repo's `ignored_files` — drop cache/lock files
(`.parcel-cache/*`, etc.) and keep only files that are actual secrets worth
restoring (`.env`, `.aws.tmp.creds.json`, ...).

### 3. `export-project-secrets.sh` (new, manual, run on old laptop)

Reads `.chezmoidata/projects.yaml`. For every repo, for every entry in its
(pruned) `ignored_files`, computes a Bitwarden item name:

```
proj-secret:<repo-path-relative-to-Projects-root>:<file-relative-path>
```

e.g. `proj-secret:ENI/cf-extension-demo:.env`

and calls the existing `add_secret_to_bw.sh <name> <repo>/<file>`, which
already handles "create in Bitwarden if not present" idempotently, using the
same Bitwarden folder as SSH key secrets.

### 4. `export-project-folders.sh` (new, manual, run on old laptop)

Reads `.chezmoidata/projects.yaml`. For each folder root, zips it to
`$onedriveProjectsBackupDir/<sanitized-root-name>.zip`, passing `-x`
exclusions for each of its `nested_repos` paths so nested repos are not
duplicated into the archive.

### 5. `restore-projects.sh` (new, generated from `projects.yaml`, run
   manually on new laptop)

For each repo in `projects.yaml`:
- if the target path doesn't already exist, `git clone` from its recorded
  remote to that path;
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
- `export-project-secrets.sh` relies on `add_secret_to_bw.sh`'s existing
  idempotent create-if-missing check, so re-running exports after adding new
  repos to `projects.yaml` is safe and won't duplicate Bitwarden items.
