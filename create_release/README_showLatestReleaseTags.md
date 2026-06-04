# showLatestReleaseTags.sh

A utility that scans repositories listed in a JSON configuration file
and reports the latest release-related tag for each repository.

## Requirements

-   Bash
-   `git`
-   `jq`

## Usage

``` bash
./showLatestReleaseTags.sh [config.json] [release_type]
```

  -----------------------------------------------------------------------
  Argument                         Description
  -------------------------------- --------------------------------------
  `config.json`                    Configuration file (default:
                                   `createReleaseConfig.json`)

  `release_type`                   `RC` (default) or `Official`
  -----------------------------------------------------------------------

---

## Help

Display the built-in help text:

```bash
./showLatestReleaseTags.sh --help
```

or:

```bash
./showLatestReleaseTags.sh -h
```

## Configuration

``` json
[
  {
    "repo_directory": "~/ngwpc/repositories/ngen",
    "release": "3.1.2.0.0",
    "skip": false
  }
]
```

### Fields

-   `repo_directory` -- Local git repository path.
-   `release` -- Base release version.
-   `skip` -- Optional. Used only for `RC` mode.

## Behavior

### RC Mode

-   `skip=true` → returns the release tag.
-   `skip=false` → returns the highest matching `-rcN` tag.

Example:

``` text
3.1.2.0.0-rc1
3.1.2.0.0-rc2
3.1.2.0.0-rc3
```

Result:

``` text
3.1.2.0.0-rc3
```

### Official Mode

Returns the highest matching official or hotfix tag.

Example:

``` text
3.1.2.0.0
3.1.2.0.1
3.1.2.0.2
```

Result:

``` text
3.1.2.0.2
```

## Output

For each repository the script displays:

-   Repository name
-   Selected tag
-   Tag date
-   Associated commit hash

At the end of the run it also reports the newest tag date found across
all scanned repositories.

## Notes

-   Repositories are refreshed using `git fetch --all --tags --prune`.
-   Lightweight tags use the tagged commit date when no tagger date
    exists.
-   Invalid or missing repositories are reported and skipped.
-   The script expects each JSON object to include `repo_directory` and `release`.
-   The script assumes release and hotfix tags use dot-separated numeric components.
-   Official release matching is based on the final numeric component of the configured release version.
-   RC matching only supports tags ending in `-rc<number>`.
-   `release_type` is case-sensitive.
-   The final latest-tag summary considers any tag in each repository, not only release tags matching the configured release.
