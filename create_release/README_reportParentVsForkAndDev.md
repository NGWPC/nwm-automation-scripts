# reportParentVsForkAndDev.sh

Report-only utility for comparing an **upstream (parent) repository’s default branch** against **corresponding branches in your fork**, based on a JSON configuration file.

This script is designed for **inspection and governance**. It never pushes, merges, rebases, or modifies remotes.

---

## What this script compares

For each repository entry in the config file, the script:

1. Determines the **upstream default branch** (`main` or `master`)
   - Uses `upstream_default` from config if provided
   - Otherwise detects it via `git ls-remote <upstream> HEAD`

2. Compares that upstream default branch against **two branches in your fork**:
   - **Like-named branch** in the fork  
     (e.g. upstream `main` → fork `origin/main`)
   - **Development branch** in the fork  
     (default: `origin/development`, configurable)

3. Reports **counts of commits present on the upstream default branch** that are **missing from**:
   - the fork’s like-named branch
   - the fork’s development branch

With `-v`, it also lists the missing commits per repository.

> **Important:**  
> This script intentionally does **not** compare against your fork’s *default* branch unless it happens to share the same name as the upstream default or `development` is your local *default* branch.

---

## Usage

```bash
reportParentVsForkAndDev.sh [-c <config.json>] [-d <dev-branch>] [-p <parent-org>] [-H <host>] [--https] [-v] [-h]
```

---

## Options

| Option | Description | Default |
|------|-------------|---------|
| `-c <config.json>` | Config file path | `owpRepoSyncConfig.json` |
| `-d <dev-branch>` | Development branch name | `development` |
| `-p <parent-org>` | Parent org / user | `NOAA-OWP` |
| `-H <host>` | Git host | `github.com` |
| `--https` | Use HTTPS instead of SSH | SSH |
| `-v` | Verbose: list missing commits per repo | off |
| `-h` | Help | — |

---

## Config file format

The config file is a JSON array of repository entries. Each entry controls how a repository is located locally and how its upstream is determined.

### Per-entry fields

| Field | Required | Description |
|------|----------|-------------|
| `repo_directory` | ✅ | Local path to the repository |
| `upstream_repo` | optional | Upstream in `ORG/REPO` form (e.g. `NOAA-OWP/cfe`) |
| `upstream_url` | optional | Full upstream URL (e.g. `git@github.com:NOAA-OWP/cfe.git`) |
| `upstream_default` | optional | Explicit upstream default branch (`main` / `master`) |
| `upstream_local_branch` | optional | Local branch name corresponding to upstream default |
| `skip` | optional | `true` to silently ignore this entry |

---

### Example config file

```json
[
  {
    "repo_directory": "~/ngwpc/repositories/cfe",
    "upstream_repo": "NOAA-OWP/cfe",
    "upstream_default": "master",
    "upstream_local_branch": "master",
    "skip": false
  }
]
```

---

## Branch comparison rules

- **Upstream default branch**  
  Determined per repo (config override or auto-detection)

- **Fork like-named branch**  
  `origin/<upstream_default>`

  - If this branch does not exist in the fork, the repo is skipped
  - There is no fallback to the fork’s default branch

- **Fork development branch**  
  `origin/<dev-branch>` (default: `origin/development`)

---

## Output

For each repository, the script prints a summary row including:

- repository name
- upstream default branch
- fork branch compared (`origin/<upstream_default>`)
- number of commits missing from the fork like-named branch
- number of commits missing from the development branch

With `-v`, missing commits are listed after the summary.

---

## Requirements / assumptions

- `git` is installed and available on `PATH`
- You have access to the upstream and fork repositories
- Fork repositories contain a branch matching the upstream default name
- The development branch exists in the fork (unless intentionally skipped)
