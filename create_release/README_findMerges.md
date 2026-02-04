# find_merges.sh

`findMerges.sh` scans a JSON configuration file containing `repo_directory` entries and reports which repositories have changes on a target branch after a specified date/time.

It supports two scan modes:

- **`--mode any`(default)**: looks for *any commits added* to the branch after the cutoff.  
  ✅ Catches merge commits, rebases, squash merges, fast-forward merges — anything that lands on the branch

- **`--mode merges`**: looks for *merge commits* only (`git log --merges`).  
  ✅ Catches “Create a merge commit” merges  
  ❌ Does **not** catch “Rebase and merge”, squash merges, or fast-forward merges

By default it prints only the repository names that had changes. Use **`-v`** to list the matching commits in a summary table.

---

## Requirements

- `bash`
- `git`
- `jq`

---

## Config file format

The script expects a JSON array of objects containing a `repo_directory` field:

```json
[
  {
    "repo_directory": "~/ngwpc/repositories/cfe",
    "release": "3.1.2.1.0",
    "previous_release_tag": "3.1.2.0.0",
    "release_notes": "GetLogLevel and IsLoggingEnabled public methods",
    "commit_summary": "",
    "skip": true
  },
  {
    "repo_directory": "~/ngwpc/repositories/t-route",
    "release": "3.1.2.2.0",
    "previous_release_tag": "3.1.2.1.0",
    "release_notes": "Use named logger, coastal coupling fix.",
    "commit_summary": "",
    "skip": false
  }
]
```

Only `repo_directory` is used by this script.

---

## Usage

```bash
./findMerges.sh -a "<after-datetime>" [-c <config.json>] [-b <branch>] [-v] [--mode any|merges]
```

### Required

- `-a "<after-datetime>"`  
  Date/time string understood by git. Examples:
  - `"2026-01-27"`
  - `"2026-01-27 19:15"`
  - `"2026-01-27 19:15:08"`
  - `"2026-01-27 19:15:08 -0500"`

### Optional

- `-c <config.json>`  
  Config file to use (default: `createReleaseConfig.json`)
- `-b <branch>`  
  Branch to scan (default: `ngwpc-candidate`)
- `-v`  
  Verbose output (lists commits in a summary table)
- `--mode any|merges`  
  Scan mode (default: `any`)
- `-h`  
  Show help

---

## Examples

### Default behavior (merge commits only, just list repos)

```bash
./find_merges.sh -a "2026-01-27 19:15:08"
```

### Detect rebases and squash merges

```bash
./find_merges.sh -a "2026-01-27 19:15:08" --mode any
```

### Verbose: list all matching commits

```bash
./find_merges.sh -a "2026-01-27 19:15:08" --mode any -v
```

Example output:

```text
Summary (verbose)
=============================================================
Repository                | Date       | Commit   | Message
-------------------------------------------------------------
cfe                        | 2026-01-28 | a3f9c2d  | Fix logging config (#418)
cfe                        | 2026-01-28 | 19fe0aa  | Update docs (#419)
```

### Scan a different branch

```bash
./find_merges.sh -a "2026-01-27 19:15:08" -b development --mode any
```

### Use an alternate config file

```bash
./find_merges.sh -a "2026-01-27 19:15:08" -c altConfig.json --mode any
```

---

## Notes

### Merge commits vs rebase/squash merges

If your team sometimes uses **GitHub “Rebase and merge”** or **“Squash and merge”**, you should use:

```bash
--mode any
```

because those workflows often do **not** create merge commits.

### Timestamp behavior

- In `--mode merges`, the cutoff is applied via:
  ```bash
  git log --after="<after-datetime>" --merges
  ```
- In `--mode any`, the script finds the branch tip as-of the cutoff time and lists commits added afterward.

---

## Exit codes

- `0` — success (including “no matches found”)
- `2` — usage or configuration error
