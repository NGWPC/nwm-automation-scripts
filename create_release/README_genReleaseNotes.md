# genReleaseNotes

`genReleaseNotes.py` generates customer-facing release notes for one or more Git repositories. It checks out a release branch, fetches current branches and tags, resolves the effective release tag including the latest hotfix/patch tag, records the full commit SHA for that release tag, synthesizes a one-paragraph summary, generates comprehensive Additions, Removals, and Changes sections, and preserves the raw commit list for traceability.

## Key Features

- Generates Markdown, text, or both output formats.
- Processes multiple repositories from a single JSON configuration file.
- Checks out a configured branch before collecting release information.
- Fetches all remotes and tags before generating release notes.
- Resolves the latest patch/hotfix tag for version patterns like `3.1.2.0.0`, `3.1.2.0.1`, and `3.1.2.0.2`.
- Includes the full commit SHA for the effective release tag.
- Generates a concise one-paragraph Summary from the commit list.
- Generates comprehensive Additions, Removals, and Changes sections from grouped commit themes.
- Excludes low-value noise such as merge commits, formatting-only commits, typo fixes, comments, TODO-only commits, and WIP commits.
- Keeps the raw commit list unchanged for review and audit purposes.

## Output Structure

Markdown output is organized like this:

```markdown
# Release Notes (YYYY-MM-DD)

## Table of Contents

## repository-name
- **Release Notes**: release note label
- **Configured Release Version**: `configured-tag`
- **Effective Release Version**: `resolved-tag`
- **Release Commit SHA**: `full-release-tag-sha`
- **Previous Release**: `previous-tag`

### Summary
Generated one-paragraph summary.

### Additions
- Comprehensive summary of added capabilities grouped from matching commits.

### Removals
- Comprehensive summary of removed code, dependencies, assets, or debug/test artifacts.

### Changes
- Comprehensive summary of changed behavior, refactoring, configuration, testing, CI/CD, Docker, validation, and model updates.

### Commits
- Raw commit subject (short-hash)
```

Text output contains the same repository metadata, generated Summary, Additions, Removals, Changes, and raw Commits in a plain text format.

## Requirements

The script requires:

- Python 3.8 or newer.
- Git installed and available on `PATH`.
- Local clones of the repositories listed in the config file.
- Access to the remote repositories so `git fetch --all --tags --prune` and `git pull origin <branch>` can run.

The script uses only Python standard library modules.

## Configuration File Format

The script expects a JSON file containing a list of repository entries.

Example `createReleaseConfig.json`:

```json
[
  {
    "repo_directory": "~/repos/ngen",
    "release": "3.1.2.0.0",
    "previous_release_tag": "3.1.1.0.0",
    "release_notes": "NWM 3.1.2.0.0"
  },
  {
    "repo_directory": "~/repos/nwm-verf",
    "release": "3.1.2.0.0",
    "previous_release_tag": "3.1.1.0.0",
    "release_notes": "NWM 3.1.2.0.0",
    "skip": false
  }
]
```

### Config Fields

| Field | Required | Description |
|---|---:|---|
| `repo_directory` | Yes | Local path to the Git repository. `~` is expanded automatically. |
| `release` | Yes | Configured release tag. The script may resolve this to a later patch tag. |
| `previous_release_tag` | Yes | Previous release tag used as the lower bound for the commit range. Use an empty string or `null` only when generating notes from the beginning of repository history. |
| `release_notes` | Yes | Label shown in the generated release notes metadata. |
| `skip` | No | When `true`, the repository is skipped. Defaults to `false`. |

## Command Line Usage

Basic Markdown output:

```bash
python genReleaseNotes.py \
  --config createReleaseConfig.json \
  --output_md release_notes
```

This writes:

```text
release_notes.md
```

Basic text output:

```bash
python genReleaseNotes.py \
  --config createReleaseConfig.json \
  --output_txt release_notes
```

This writes:

```text
release_notes.txt
```

Generate both Markdown and text:

```bash
python genReleaseNotes.py \
  --config createReleaseConfig.json \
  --output_both release_notes
```

This writes:

```text
release_notes.md
release_notes.txt
```

Use a specific checkout branch:

```bash
python genReleaseNotes.py \
  --config release_repos.json \
  --checkout-branch ngwpc-candidate \
  --output_md release_notes
```

The default checkout branch is:

```text
ngwpc-release
```

## Output Options

The output arguments are mutually exclusive. Exactly one is required.

| Option | Behavior |
|---|---|
| `--output NAME` | Writes Markdown. Keeps the provided extension if one is supplied; otherwise appends `.md`. |
| `--output_md NAME` | Writes Markdown and forces `.md`. |
| `--output_txt NAME` | Writes text and forces `.txt`. |
| `--output_both NAME` | Writes both `.md` and `.txt`. |

Examples:

```bash
--output release_notes
```

writes `release_notes.md`.

```bash
--output release_notes.custom
```

writes `release_notes.custom`.

```bash
--output_md release_notes.custom
```

writes `release_notes.md`.

## Release Tag Resolution

The script resolves patch/hotfix tags when the configured release tag follows this pattern:

```text
<customer provided.>major.minor.patch
```

For example, if the config specifies:

```text
3.1.2.0.0
```

and the repository contains:

```text
3.1.2.0.0
3.1.2.0.1
3.1.2.0.2
```

then the script uses:

```text
3.1.2.0.2
```

as the effective release tag.

The generated metadata will show both values:

```markdown
- **Configured Release Version**: `3.1.2.0.0`
- **Effective Release Version**: `3.1.2.0.2`
```

## Release Commit SHA

The script records the full commit SHA for the effective release tag using:

```bash
git rev-list -n 1 <effective-release-tag>
```

This works for both lightweight and annotated tags.

Example output:

```markdown
- **Release Commit SHA**: `abcdef1234567890abcdef1234567890abcdef12`
```

## Commit Range

When `previous_release_tag` is provided, commits are collected with:

```bash
git log <previous_release_tag>..<effective_release_tag> --pretty=format:'%s (%h)'
```

When `previous_release_tag` is omitted or empty, commits are collected from the effective release tag history with:

```bash
git log <effective_release_tag> --pretty=format:'%s (%h)'
```

The raw commit section preserves the commit subjects and short hashes exactly as returned by Git, except for filtered merge commits.

## Generated Summary Behavior

The Summary section is generated directly from the commit list. It is intended to be a concise, customer-facing paragraph.

The generated summary follows these rules:

- Write a single paragraph.
- Describe what changed, not the motivation behind the changes.
- Consolidate related commits into high-level themes.
- Exclude merge, formatting, typo, comment, TODO-only, and WIP commits.
- Avoid explanatory wording such as “to improve reliability” or “to support future development.”
- Use professional release-note language.

The summary is generated from theme rules in `SUMMARY_THEME_RULES`. Each matching theme contributes a sentence such as:

```text
Integrated EWTS logging support and updated logging behavior across components.
```

or:

```text
Updated state serialization, deserialization, reset-time, and restart handling.
```

The script selects the highest-priority and most frequently matched themes so the Summary stays concise.

## Additions, Removals, and Changes Sections

The Additions, Removals, and Changes sections are not simple commit categorizations. They are fuller summary descriptions of the commits associated with each section.

Each section is generated by:

1. Filtering noisy commits.
2. Matching remaining commits against `SECTION_THEME_RULES`.
3. Grouping related commits into themes.
4. Emitting comprehensive summary sentences for each matched theme.
5. Rolling unmatched but relevant commits into a compact fallback sentence.

Example section output:

```markdown
### Additions
- Implemented and expanded serialization support, including serialized size metadata, message constants, integer-based transfer structures, deserialization bounds handling, and state-transfer messaging.
- Integrated EWTS logging support across affected components, including module-specific logging updates, optional logging behavior, Docker/build integration, and unit-test coverage where applicable.
```

```markdown
### Changes
- Reworked serialization behavior, message metadata, reported state types, size calculations, buffer validation, and transfer logic for state save and restore workflows.
- Corrected unit conversions and size/type reporting across model calculations, serialized buffers, time-step handling, and BMI-facing data exchanges.
```

## Theme Coverage

The script contains theme rules for common NGWPC/NWM release-note topics, including:

- EWTS logging.
- Serialization and deserialization.
- State saving, restart, reset-time, and hindcasting.
- Verification, metrics, observations, USGS, TxDOT, and plotting.
- Forcing workflows and forecast products.
- NHF, hydrofabric, geopackages, VPUs, and crosswalks.
- BMI model behavior.
- Geospatial metadata and regridding.
- Hydrologic model outputs and model-specific updates.
- SAC-SMA, CFE, Snow-17, SFT, SMP, and Noah-OWP related updates.
- Testing and expected results.
- CI/CD and downstream pipeline triggers.
- Docker, build, packaging, dependencies, and installed resources.
- Validation, warnings, exceptions, permissions, and user-facing errors.
- Cache, dataset, temporary file, scratch directory, and S3/local data access behavior.
- Cleanup and refactoring.

## Noise Filtering

The script filters commits that are unlikely to be useful in customer-facing release notes. Examples include:

- Merge commits.
- Rebase commits.
- WIP commits.
- Formatting/linting-only commits.
- Typo-only commits.
- Docstring/comment-only commits.
- TODO-only commits.

The filtering is controlled by `NOISE_PATTERNS`.

## Customizing the Generated Content

Most customization happens in three places:

### `SUMMARY_THEME_RULES`

Controls the one-paragraph Summary section.

Add a new theme when a repository has recurring commit language that should influence the overall summary.

Example:

```python
{
    "theme": "routing",
    "keywords": ["troute", "routing", "route"],
    "sentence": "Updated routing and t-route integration behavior.",
    "priority": 75,
}
```

### `SECTION_THEME_RULES`

Controls Additions, Removals, and Changes section summaries.

Add a new rule when commits should be grouped into a fuller section description.

Example:

```python
{
    "section": "Changes",
    "theme": "routing",
    "keywords": ["troute", "routing", "route"],
    "summary": "Updated routing configuration, t-route integration, and route-specific workflow behavior.",
}
```

### `NOISE_PATTERNS`

Controls which commits are excluded from generated summaries and sections.

Use this carefully. A broad pattern can accidentally hide meaningful commits.

## Troubleshooting

### The generated summary is too generic

Add more keywords or a new theme to `SUMMARY_THEME_RULES` and `SECTION_THEME_RULES` for the missing domain.

For example, if commits mention a model name such as `LASAM`, `UEB`, or `Topoflow`, add those terms to the relevant model-output, forcing, or BMI theme.

### A meaningful commit is missing from Additions, Removals, or Changes

Check whether it was filtered by `NOISE_PATTERNS`. If not, add keywords to an existing `SECTION_THEME_RULES` entry or create a new theme.

### Too many items appear in a section

The script groups by theme, not by individual commit. If too many items appear, similar themes may need to be consolidated in `SECTION_THEME_RULES`.

### The wrong release tag is used

Run:

```bash
git tag | sort -V
```

inside the repository and confirm the configured release tag follows the expected version pattern. The patch-tag resolver only applies to tags matching:

```text
number.number.number.number.number
```

### The script fails during checkout

Confirm the branch exists locally or can be checked out from the remote:

```bash
git branch --all | grep ngwpc-release
```

You can also specify a different branch:

```bash
--checkout-branch ngwpc-candidate
```

### The script fails during pull

The script runs:

```bash
git pull origin <checkout-branch>
```

Make sure the local repository has no unresolved conflicts and that the remote branch exists.

### The script reports `No commits found.`

Confirm both tags exist in the repository:

```bash
git tag | grep <tag-name>
```

Then verify the commit range manually:

```bash
git log <previous-tag>..<effective-release-tag> --oneline
```

## Suggested Workflow

1. Confirm all repositories have the latest release tags.
2. Create or update the JSON config file.
3. Run the script with `--output_both`.
4. Review the generated Summary, Additions, Removals, and Changes sections.
5. Review the raw Commits section for traceability.
6. Add theme keywords to the script if a repository’s commit language is not being summarized well.
7. Re-run the script.

Example:

```bash
python genReleaseNotes.py \
  --config release_repos.json \
  --checkout-branch ngwpc-release \
  --output_both nwm_release_notes
```

## Notes and Limitations

This script uses deterministic keyword-based summarization. It does not call an external AI model or API. That makes it simple and repeatable, but it also means summary quality depends on the theme dictionaries and commit wording.

For best results, keep commit messages descriptive and domain-specific. Commit subjects such as `fix bug`, `updates`, or `cleanup` provide very little information for the summarizer. Commit subjects that mention the affected model, workflow, or feature generate much better release-note output.

