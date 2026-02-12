# genReleaseNotes.py

Generate consolidated release notes across multiple Git repositories using a JSON configuration file.

This script supports Markdown, plain text, or both output formats, automatically extracts commit messages between Git tags, and optionally generates a Table of Contents for Markdown output.

---

## Features

- Generate **Markdown (`.md`)**, **text (`.txt`)**, or **both** formats
- Supports multiple repositories via a JSON config file
- Automatically pulls latest changes before generating notes
- Extracts commit summaries between release tags
- Filters out merge commits
- Auto-generates a Markdown Table of Contents
- Skips repositories marked with `"skip": true`

---

## Requirements

- Python 3.8+
- Git installed and available in `PATH`
- Local clones of all repositories referenced in the config file

---

## Usage

```bash
python genReleaseNotes.py -c <config.json> [output option]
```

### Output Options (mutually exclusive)

| Option | Description |
|------|------------|
| `--output <name>` | Output file (defaults to `.md` if no extension) |
| `--output_md <name>` | Force Markdown output |
| `--output_txt <name>` | Force text output |
| `--output_both <base>` | Generate both `<base>.md` and `<base>.txt` |

---

## Example Commands

Generate Markdown release notes:
```bash
python genReleaseNotes.py -c createReleaseConfig.json --output release-notes
```

Generate text-only output:
```bash
python genReleaseNotes.py -c createReleaseConfig.json --output_txt release-notes.txt
```

Generate both Markdown and text:
```bash
python genReleaseNotes.py -c createReleaseConfig.json --output_both release-notes
```

---

## Configuration File Format

The config file must be a JSON array. Each entry describes one repository.

```json
[
  {
    "repo_directory": "~/repos/example-repo",
    "release": "v2.1.0",
    "previous_release_tag": "v2.0.0",
    "release_notes": "Bug fixes and performance improvements",
    "commit_summary": "This release focuses on stability and minor enhancements.",
    "skip": false
  }
]
```

### Fields

| Field | Required | Description |
|-----|----------|-------------|
| `repo_directory` | Yes | Local path to the git repository |
| `release` | Yes | Git tag or ref for the release |
| `previous_release_tag` | No | Previous release tag (optional) |
| `release_notes` | Yes | Short release notes |
| `commit_summary` | Yes | Summary paragraph |
| `skip` | No | If `true`, repository is skipped |

---

## Markdown Output Structure

```markdown
# Release Notes (YYYY-MM-DD)

## Table of Contents
- [repo-name](#repo-name)

## repo-name
- Release Notes
- Release Version
- Previous Release

### Summary
<summary text>

### Commits
- Commit message (hash)
```

---

## How Commits Are Determined

- If `previous_release_tag` is provided:
  - Uses `git log prev..release`
- If omitted:
  - Uses `git log release`
- If tags are identical:
  - Outputs "No changes."
- Merge commits are filtered out automatically

---

## Notes & Behavior

- The script runs `git pull` on each processed repository
- Markdown TOC anchors are generated from repository names
- Output files are overwritten for Markdown, appended for text output
- Errors from Git commands are printed but do not abort execution

---
