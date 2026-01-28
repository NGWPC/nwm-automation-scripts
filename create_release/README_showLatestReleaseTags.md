# showLatestReleaseTags.sh

## Usage

```bash
showLatestReleaseTags.sh [config.json] [release_type]
```

## Description

Scans git repositories listed in a JSON config file and prints either the release tag or the highest release candidate tag (`-rcX`), along with the tag creation date and associated commit hash.

## Arguments

| Argument       | Description |
|----------------|-------------|
| `config.json`  | Optional. Path to JSON config file. Default: `createReleaseConfig.json` |
| `release_type` | Optional. Type of release: `RC` (default) or `Official`. <br> `RC` → use the release tag if skip is true otherwise the highest release candidate tag (-rcX) <br> `Official` → selects only the release tag. |

## Options

| Option          | Description |
|----------------|-------------|
| `-h`, `--help` | Show this help message and exit. |

## Tag Behavior (RC only)

| `skip` value  | Behavior |
|---------------|----------|
| `true`        | Use `<release>` tag |
| `false`       | Use the highest release candidate `<release>-rc<number>` tag |

## Example JSON Config Entry

Minimal required fields:

```json
[
    {
        "repo_directory": "~/ngwpc/repositories/noah-owp-modular",
        "release": "3.1.2.0.0"
    }
]
```
> Notes:
> - `repo_directory` supports `~` for the home directory.  
> - `skip` determines whether to select the final release tag (`true`) or the highest release candidate tag (`false`) when `release_type` is `RC`.
