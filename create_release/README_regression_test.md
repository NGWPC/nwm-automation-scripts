# regression_test.py — Documentation

This document describes how to use `regression_test.py` to exercise `createRelease.sh` end-to-end against real sandbox repositories and real GitHub state — no mocking of `git`/`gh`. It covers prerequisites, command-line usage, what each scenario checks, and how to read the results.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Sandbox Repositories](#sandbox-repositories)
4. [Command-Line Usage](#command-line-usage)

   * [Options](#options)
   * [Running Everything vs. One Test](#running-everything-vs-one-test)
5. [Scenario Groups](#scenario-groups)
6. [Submodule Scenarios in Detail](#submodule-scenarios-in-detail)
7. [Per-Check Logging](#per-check-logging)
8. [Reading the Summary](#reading-the-summary)
9. [Exit Codes](#exit-codes)
10. [Related Scripts](#related-scripts)
11. [Examples](#examples)
12. [Troubleshooting](#troubleshooting)

---

## Overview

`regression_test.py` drives the actual `createRelease.sh` binary — feeding it real command-line flags and real stdin for its interactive prompts — against three real GitHub repositories, then asserts on the resulting git/GitHub state (tags, branches, PR merges, submodule gitlinks, changelog files). Nothing about `git` or `gh` is mocked; this is the same script doing the same things it would do in a real release, just against disposable sandbox repos.

Each scenario is a small Python function that:

1. Builds a JSON config (via `Harness.write_config`) and/or makes real commits (via `Harness.make_submodule_commit`, which shells out to `makeTestCommit.sh`).
2. Invokes `createRelease.sh` through `Harness.run_release`, feeding canned stdin for every interactive prompt.
3. Asserts on the result — exit code, stdout content, existing tags/branches, or exact submodule gitlink SHAs read straight from the remote tree.
4. Calls `record(name, passed, detail)` to log the verdict.

Because it hits real GitHub, releases/tags/PRs from a given run are **not** cleaned up automatically — each scenario uses a fresh timestamp-based release base (e.g. `0.0.1737400000i`) so re-runs never collide with a previous run's tags. Run [`reset_test_repos.sh`](#related-scripts) beforehand for a clean slate, and periodically with `--nuke` to clear out accumulated test tags/releases/branches.

---

## Prerequisites

Same as `createRelease.sh` itself, since this literally invokes it:

1. **Bash**, **`git`**, **`jq`**, **`sed`** on `PATH`.
2. **GitHub CLI (`gh`)**, authenticated.
3. **Python 3.9+** (uses `str.removeprefix`, PEP 604-adjacent type hints via `list[Result]`).
4. Local clones of the three sandbox repos with real GitHub remotes (see below).
5. `makeTestCommit.sh` present (defaults to the same directory as `--script`) — required by the submodule pointer-update scenarios.

---

## Sandbox Repositories

Three repos, defaulting to sibling directories of the current working directory:

| Flag | Default | Role |
|---|---|---|
| `--repo1` | `./peter_test1` | Plain repo, no submodules |
| `--repo2` | `./peter_test2` | Has submodules (`has_submodules: true` scenarios run against this one) |
| `--sub1` | `./peter_test_sub1` | The submodule of `peter_test2`; also usable standalone |

**Important prerequisite for the submodule scenarios:** `peter_test_sub1` needs its own `development`, `development-pw`, `ngwpc-candidate`, `ngwpc-candidate-pw`, `ngwpc-release`, and `ngwpc-release-pw` branches already pushed to its origin. `createRelease.sh` only ever follows a same-named branch in a submodule — it never creates one there — so these have to exist ahead of time (e.g. by running `createRelease.sh` standalone against `peter_test_sub1` once for each release type/environment). Each submodule scenario checks for the specific branches it needs before doing anything else, and fails with a clear "peter_test_sub1 is missing branch(es) [...]" message rather than erroring out deep inside a run if they're absent.

---

## Command-Line Usage

```bash
# from a directory containing createRelease.sh, peter_test1, peter_test2,
# and peter_test_sub1 (all default to cwd-relative paths):
python3 regression_test.py

# or override any of them:
python3 regression_test.py \
    --script /path/to/createRelease.sh \
    --repo1  /path/to/peter_test1 \
    --repo2  /path/to/peter_test2 \
    --sub1   /path/to/peter_test_sub1
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--script` | `./createRelease.sh` | Path to the script under test |
| `--repo1` | `./peter_test1` | Path to the no-submodules sandbox repo |
| `--repo2` | `./peter_test2` | Path to the has-submodules sandbox repo |
| `--sub1` | `./peter_test_sub1` | Path to the submodule repo |
| `--make-commit-script` | `makeTestCommit.sh` next to `--script` | Path to `makeTestCommit.sh`, used by submodule scenarios |
| `--run-cwd` | current directory | Directory `createRelease.sh` is actually invoked from (config file paths, logs, and `changelogs/` all land here) |
| `--scenario` | `all` | Comma-separated group names to run (see [Scenario Groups](#scenario-groups)), or `all` |
| `--test` | *(none)* | Comma-separated individual test keys — overrides `--scenario` entirely when given |
| `--list-tests` | — | Print every individual test key, grouped, and exit (no repos touched) |

### Running Everything vs. One Test

Running with no flags at all runs every scenario in every group — `--scenario` defaults to `all`, and since `--test` defaults to nothing, the full suite runs exactly as if you'd typed `--scenario all`.

To narrow down to specific groups:
```bash
python3 regression_test.py --scenario rc,official
```

To run one or two specific tests instead of a whole group — handy when you're chasing down a single failure and don't want to wait through everything else:
```bash
python3 regression_test.py --list-tests
python3 regression_test.py --test submodule_pointer_update
python3 regression_test.py --test rc_pw_environment,submodule_pointer_update
```
`--test` takes priority over `--scenario` whenever both are given.

---

## Scenario Groups

| Group | Tests | What it covers |
|---|---|---|
| `config` | `help`, `missing_release_type`, `invalid_release_type`, `missing_config_file`, `malformed_json`, `non_array_json`, `bad_wait_time`, `bad_environment`, `bad_repo_env_field`, `missing_repo_directory`, `skip_flag`, `confirmation_abort`, `env_pw_skipped_under_standard`, `env_aws_skipped_under_pw`, `env_all_runs_under_both`, `env_absent_defaults_to_all` | Argument parsing, config validation, the per-repo `env` targeting rules, and the initial Y/N confirmation — no releases actually get created |
| `rc` | `rc_lifecycle`, `rc_duplicate_tag_rejected`, `rc_pw_environment` | Full RC1 → RC2 lifecycle (tag, pre-release, merge-back on RC2 only), duplicate-tag rejection, and the same lifecycle under `-e PW` |
| `official` | `official_lifecycle` | Full OFFICIAL flow: changelog generation, tag, GitHub release, merge-back to `development` |
| `owp` | `owp_branch_only` | OWP mode creates only a branch — no tag, no release, no PR |
| `submodule` | `submodule_pointer_update`, `submodule_pointer_update_pw`, `submodule_pointer_update_official`, `submodule_pointer_update_official_pw`, `submodule_manual_is_default`, `submodule_noop_without_gitmodules` | See [Submodule Scenarios in Detail](#submodule-scenarios-in-detail) |

Run `--list-tests` any time to get this same mapping straight from the code rather than this document, in case they've drifted apart.

---

## Submodule Scenarios in Detail

These are the most involved scenarios, since they need to prove a submodule's gitlink pointer actually changed to a specific, real commit — not just that the code path ran.

* **`submodule_pointer_update`** (RC, STANDARD) — makes a distinguishing commit on `peter_test_sub1`'s `ngwpc-candidate` branch, runs RC1, and checks the parent's recorded gitlink for that submodule now matches that exact commit. Then makes a second, different commit on `development`, runs RC2 (which is what actually merges back to `development`), and checks that pointer too. Two distinct commits are used specifically so a pointer landing on the wrong branch's SHA gets caught, rather than being masked by reusing one commit everywhere.
* **`submodule_pointer_update_pw`** — the same shape, under `-e PW`, against `ngwpc-candidate-pw` / `development-pw`.
* **`submodule_pointer_update_official`** — runs a plain RC1 first (so `ngwpc-candidate` has something to merge from), then makes distinguishing commits on both `ngwpc-release` and `development`, runs OFFICIAL once (which merges back to `development` unconditionally, unlike RC1), and checks both pointers landed correctly from that single run.
* **`submodule_pointer_update_official_pw`** — same, under `-e PW`.
* **`submodule_manual_is_default`** — the odd one out: it verifies the *default* behavior does **nothing** automatically. It establishes a known-good candidate pointer with `--automatic-submodules` first, makes another distinguishing commit, then runs RC2 again with **no** flag at all, and asserts the pointer is unchanged (rather than picking up the new commit) and that the manual-pause message appeared in stdout. This is what actually proves manual mode is inert by default, not just that the flag exists.
* **`submodule_noop_without_gitmodules`** — confirms `has_submodules: true` against a repo with no `.gitmodules` file is a harmless no-op, regardless of automatic/manual mode.

Every one of the first four passes `--automatic-submodules` explicitly to `run_release`, since `createRelease.sh`'s own default is now manual (a pause, not an update) — without that flag none of these runs would touch a gitlink at all, and every SHA assertion would simply fail.

> **Known issue:** `ngwpc-candidate`, `ngwpc-release`, and their `-pw` counterparts can't be deleted on origin — GitHub branch protection blocks it, and `reset_test_repos.sh --nuke` can only remove them locally (see its own comments). That means there's no real way to fully reset these branches between runs; whatever state they're in on GitHub carries forward. Most of the time that's harmless, but the submodule pointer-update tests check an *exact* SHA rather than just "did something change," so if one of these branches has drifted out of sync with what a given repo's history expects — from an interrupted earlier run, a manual experiment, or just running the suite many times — a test can fail (or intermittently pass/fail) for reasons that have nothing to do with the code under test. If a submodule pointer-update failure doesn't match what the log shows `createRelease.sh` actually doing, suspect drift on these protected branches before assuming a real regression — at the moment, resolving it means someone with admin/bypass rights resetting the branch on GitHub directly.

---

## Per-Check Logging

Every `sh()`/`git()` call since the *previous* `record()` call is buffered and, the moment a check's result is recorded, flushed to its own log file — named after the check itself, not a timestamp — under:

```
<run-cwd>/regression_logs/<check_name>.log
```

For example, a failure in "RC1 picks up new submodule commit on ngwpc-candidate" writes `regression_logs/rc1_picks_up_new_submodule_commit_on_ngwpc_candidate.log`, containing every command that ran (and its exit code, stdout, stderr) since the previous check finished — nothing from earlier or later checks mixed in. On failure, the console output also prints that filename plus the last ~15 lines of actual output inline, so most failures are diagnosable without opening anything. The final summary lists the log filename next to every result, pass or fail.

A command that hits the harness's own timeout ceiling (see [`run_release`](#options) — 60 seconds by default) doesn't just vanish into an uncaught exception; it's turned into a normal (failing) result with whatever output the killed process had already produced still captured in the log.

---

## Reading the Summary

```
=== Summary ===
  [PASS] RC1 creates ngwpc-candidate and tags -rc1  (rc_lifecycle.log)
  [FAIL] RC2 merge-back picks up new submodule commit on development  (rc2_merge_back_picks_up_new_submodule_commit_on_development.log)
  ...

23/25 passed
```

Every line shows the check's log filename (see above), whether it passed or not, so you can always go straight to the transcript for any result without hunting through timestamped `createRelease_*.log` files from the script itself.

---

## Exit Codes

* **`0`** — every check passed.
* **`1`** — at least one check failed.
* **`2`** — bad invocation: an unknown `--scenario` group name or an unknown `--test` key was given (with the available options printed to stderr).

---

## Related Scripts

* **`reset_test_repos.sh`** — puts the three sandbox repos back to a known baseline before a full run: checks out and fast-forwards `development`, prunes stale remote-tracking branches, and clears out any leftover `merge_test_*`, `update_submodules_*`, or `test-update-*` temp branches from an interrupted prior run. Pass `--nuke` to also remove `ngwpc-candidate`/`ngwpc-release` (and `-pw` counterparts), OWP branches, and any test tags/releases matching the `0.0.*` pattern this harness uses — needed periodically since normal runs intentionally leave real tags/PRs/releases behind.
* **`makeTestCommit.sh`** — used internally by `Harness.make_submodule_commit` to push a real, distinguishing commit onto a given branch of `peter_test_sub1` via a throwaway feature branch and PR (with a built-in retry for the transient GitHub "base branch was modified" race). Not usually run directly, but safe to — see its own `--help`.

---

## Examples

```bash
# Full suite, default paths, clean slate first
./reset_test_repos.sh
python3 regression_test.py

# Just the RC and OFFICIAL groups
python3 regression_test.py --scenario rc,official

# Chasing one failure without waiting through everything else
python3 regression_test.py --test submodule_pointer_update_pw

# See every available test key before deciding what to run
python3 regression_test.py --list-tests

# Point at repos that live somewhere other than the current directory
python3 regression_test.py \
    --script /home/carolyn/release-tools/createRelease.sh \
    --repo1 ~/sandbox/peter_test1 --repo2 ~/sandbox/peter_test2 \
    --sub1 ~/sandbox/peter_test_sub1
```

---

## Troubleshooting

* **`Unknown test: <key>`** — Run `--list-tests` to see the exact keys available; they're the function names with the `test_` prefix stripped.

* **`Unknown group: <name>`** — Valid groups are `config`, `rc`, `official`, `owp`, `submodule`.

* **A submodule scenario fails immediately with "peter_test_sub1 is missing branch(es) [...]"** — Exactly what it says: push the named branch(es) to `peter_test_sub1`'s origin first (see [Sandbox Repositories](#sandbox-repositories)). This check exists specifically so this shows up as a clear, immediate failure instead of an obscure error partway through a run.

* **A scenario hangs and then fails with a timeout** — Check that check's log file; the harness preserves whatever output the process produced before being killed. A likely cause on the `createRelease.sh` side is a merge that got queued (auto-merge) but never actually completed — see the `createRelease.sh` README's Troubleshooting section for `poll_merge_status`-related causes.

* **A submodule test fails with a GitHub `GraphQL: Base branch was modified` error inside `makeTestCommit.sh`'s output** — This should be rare; `makeTestCommit.sh` already retries this specific transient error a few times before giving up. If it still fails, re-run the scenario — it's a timing race, not a logic bug.

* **Re-running leaves behind tags/PRs/releases on the sandbox repos** — Expected. Each scenario's release base is timestamped specifically so this is safe; periodically run `reset_test_repos.sh --nuke` to clear the accumulated test artifacts.

* **A scenario that touches `peter_test2`'s submodule seems to pass but the pointer looks wrong on GitHub** — Double check whether that scenario passed `--automatic-submodules`; if it didn't (or you're testing a change that dropped it), `createRelease.sh` just pauses and does nothing to the pointer by default, and the harness would need to feed a `C` and inspect the pointer manually rather than asserting on it directly.
