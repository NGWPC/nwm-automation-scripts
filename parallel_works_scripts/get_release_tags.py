#!/usr/bin/env python3
"""Resolve the release tag for every repo the PW cluster release deploy needs.

The release process saves its per-repo release versions in a
createReleaseConfig json under create_release/jsons/ in this repo. This
script reads that json (the newest dated file by default), maps each deploy
repo to its "release" value, and prints one "export VAR=TAG" line per repo
using the same variable names and order as the "Deploy the Release on the
Cluster" section of the PW Confluence doc. The release value from the json
is used exactly as written, release candidate or final; this script never
builds or appends rc parts.

To load the variables straight into your CURRENT terminal session (so the
rest of the deploy steps can use them without setting anything by hand),
source the companion script, which runs this one and evals its output:

  source parallel_works_scripts/get_release_tags.sh
  source parallel_works_scripts/get_release_tags.sh --pw

Running this python script directly still works: paste or eval its stdout.

By default every tag is verified to exist on the NGWPC GitHub repo with
git ls-remote before anything is printed, so a config that was never pushed,
or a tag that was never created, fails loudly instead of quietly deploying
the wrong versions. Status and warnings go to stderr; stdout carries only
the export lines, so output can be redirected or eval'd safely.

Repos that deploy on both AWS and PW will carry two tag variants per release:
a bare tag and a -pw tag (the bare tag with -pw appended). Pass --pw to
select the -pw variants; the default is the bare tags.

Examples:
  source parallel_works_scripts/get_release_tags.sh
  source parallel_works_scripts/get_release_tags.sh --pw
  python3 parallel_works_scripts/get_release_tags.py
  python3 parallel_works_scripts/get_release_tags.py --json create_release/jsons/createReleaseConfig_20260609.json --no-verify
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

GITHUB_ORG = "NGWPC"

# Deploy repo -> shell variable name, in the same order as the Confluence
# deploy block. nwm-coastal is checked out on the cluster under the
# coastal-calibration directory, hence the different variable name.
REPO_VARS = [
    ("ngencerf-server", "NGENCERF_SERVER_RELEASE_TAG"),
    ("ngencerf-ui", "NGENCERF_UI_RELEASE_TAG"),
    ("ngen", "NGEN_RELEASE_TAG"),
    ("ngen-forcing", "NGEN_FORCING_RELEASE_TAG"),
    ("nwm-cal-mgr", "NWM_CAL_MGR_RELEASE_TAG"),
    ("nwm-fcst-mgr", "NWM_FCST_MGR_RELEASE_TAG"),
    ("nwm-eval-mgr", "NWM_EVAL_MGR_RELEASE_TAG"),
    ("nwm-data-assimilation", "NWM_DATA_ASSIMILATION_RELEASE_TAG"),
    ("nwm-msw-mgr", "NWM_MSW_MGR_RELEASE_TAG"),
    ("nwm-ewts", "NWM_EWTS_RELEASE_TAG"),
    ("nwm-rte", "NWM_RTE_RELEASE_TAG"),
    ("nwm-region-mgr", "NWM_REGION_MGR_RELEASE_TAG"),
    ("nwm-coastal", "COASTAL_CALIBRATION_RELEASE_TAG"),
]

JSONS_DIR = Path(__file__).resolve().parents[1] / "create_release" / "jsons"


def newest_config(jsons_dir):
    """Pick the createReleaseConfig*.json with the newest date in its name.

    File names have used several date shapes (20260609, 2025-11-12,
    20251112); stripping the non-digits normalizes all of them to YYYYMMDD
    for comparison. Files without an 8-digit date (like the GitLab config)
    are ignored.
    """
    best = None
    best_date = ""
    for path in jsons_dir.glob("createReleaseConfig*.json"):
        digits = re.sub(r"\D", "", path.stem)
        if len(digits) == 8 and digits > best_date:
            best_date = digits
            best = path
    return best


def tag_exists(repo, tag):
    """Return True/False for whether the tag exists on the GitHub repo,
    or None when the lookup itself failed (network, git missing, etc.)."""
    url = "https://github.com/%s/%s.git" % (GITHUB_ORG, repo)
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--tags", url, "refs/tags/%s" % tag],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return bool(result.stdout.strip())


def main():
    parser = argparse.ArgumentParser(
        description="Print the export VAR=TAG lines for a PW cluster release "
                    "deploy from a createReleaseConfig json (source "
                    "get_release_tags.sh to load them into your shell).")
    parser.add_argument("--json", type=Path, default=None,
                        help="config file to read (default: the newest dated "
                             "createReleaseConfig*.json in %s)" % JSONS_DIR)
    parser.add_argument("--pw", action="store_true",
                        help="select the -pw tag variants: appends -pw to "
                             "every tag from the config")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip checking that each tag exists on GitHub")
    args = parser.parse_args()
    suffix = "-pw" if args.pw else ""

    config_path = args.json or newest_config(JSONS_DIR)
    if config_path is None or not config_path.is_file():
        sys.exit("ERROR: no createReleaseConfig*.json found (looked in %s); "
                 "pass one with --json" % JSONS_DIR)
    print("reading %s" % config_path, file=sys.stderr)

    with open(config_path) as f:
        entries = json.load(f)
    by_repo = {}
    for entry in entries:
        name = entry.get("repo_directory", "").rstrip("/").split("/")[-1]
        if name:
            by_repo[name] = entry

    lines = []
    problems = []
    for repo, var in REPO_VARS:
        entry = by_repo.get(repo)
        if entry is None:
            problems.append("%s: not in the config file" % repo)
            continue
        release = str(entry.get("release", "")).strip()
        if not release:
            problems.append("%s: empty release value in the config" % repo)
            continue
        tag = release + suffix
        if entry.get("skip"):
            print("WARNING: %s is marked skip in the config (not re-released "
                  "this round); using its listed tag %s" % (repo, tag),
                  file=sys.stderr)
        if not args.no_verify:
            exists = tag_exists(repo, tag)
            if exists is None:
                problems.append("%s: could not query GitHub for tag %s "
                                "(network or git problem)" % (repo, tag))
                continue
            if not exists:
                problems.append("%s: tag %s does NOT exist on github.com/%s/%s"
                                % (repo, tag, GITHUB_ORG, repo))
                continue
            print("verified %s %s" % (repo, tag), file=sys.stderr)
        lines.append("export %s=%s" % (var, tag))

    if problems:
        print("", file=sys.stderr)
        for p in problems:
            print("ERROR: %s" % p, file=sys.stderr)
        sys.exit("aborting, nothing printed: fix the config (and make sure "
                 "the release tags and the config are pushed) and rerun")

    for line in lines:
        print(line)


if __name__ == "__main__":
    main()
