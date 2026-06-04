#!/usr/bin/env python3
import json
import os
import argparse
import subprocess
import sys
from pathlib import Path
from datetime import datetime
import textwrap
import re
from collections import defaultdict

# ---------------------------------------------------------
# Normalize output filename
# ---------------------------------------------------------
def normalize_output_filename(filename: str, mode: str) -> str:
    base, ext = os.path.splitext(filename)

    if mode == "default":
        return filename if ext else f"{filename}.md"
    elif mode == "md":
        return f"{base}.md"
    elif mode == "txt":
        return f"{base}.txt"
    else:
        raise ValueError(f"Unknown output mode: {mode}")

# ---------------------------------------------------------
# Shell runner
# ---------------------------------------------------------
def run(cmd, cwd=None, check=False):
    result = subprocess.run(
        cmd,
        cwd=cwd,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    if result.returncode != 0:
        print(f"! Command failed: {cmd}")
        print(result.stderr)

        if check:
            raise RuntimeError(result.stderr)

    return result.stdout.strip()

# ---------------------------------------------------------
# Repo title
# ---------------------------------------------------------
def repo_title(path):
    return Path(path).name

# ---------------------------------------------------------
# Checkout branch before fetch/pull
# ---------------------------------------------------------
def checkout_branch(repo_dir, branch="ngwpc-release"):
    current_branch = run(
        "git rev-parse --abbrev-ref HEAD",
        cwd=repo_dir
    )

    if current_branch != branch:
        print(f"    Switching branch: {current_branch} -> {branch}")
        run(f"git checkout {branch}", cwd=repo_dir, check=True)
    else:
        print(f"    Already on branch: {branch}")

# ---------------------------------------------------------
# Find latest hotfix/patch tag
# ---------------------------------------------------------
def find_latest_patch_tag(repo_dir, tag):
    match = re.match(r"^(\\d+\\.\\d+\\.\\d+\\.\\d+)\\.(\\d+)$", tag)

    if not match:
        return tag

    prefix = match.group(1)

    tags_output = run(
        "git tag",
        cwd=repo_dir
    )

    tags = tags_output.splitlines()

    matching = []

    for t in tags:
        if re.match(rf"^{re.escape(prefix)}\\.\\d+$", t):
            matching.append(t)

    if not matching:
        return tag

    def patch_num(t):
        return int(t.split(".")[-1])

    return sorted(matching, key=patch_num)[-1]

# ---------------------------------------------------------
# Resolve release tag commit hash
# ---------------------------------------------------------
def get_tag_commit_hash(repo_dir, tag):
    """
    Return the full commit SHA that a tag ultimately references.

    `git rev-list -n 1 <tag>` resolves both lightweight tags and
    annotated tags to the commit the tag points to.
    """
    sha = run(
        f"git rev-list -n 1 {tag}",
        cwd=repo_dir
    )

    return sha if sha else "Unknown"

# ---------------------------------------------------------
# Extract commits
# ---------------------------------------------------------
def get_commit_messages(repo_dir, release, prev):
    effective_release = find_latest_patch_tag(repo_dir, release)

    if not prev:
        cmd = (
            f"git log {effective_release} "
            "--pretty=format:'%s (%h)'"
        )
        commits = run(cmd, cwd=repo_dir).splitlines()
    else:
        if effective_release == prev:
            return ["No changes."]

        cmd = (
            f"git log {prev}..{effective_release} "
            "--pretty=format:'%s (%h)'"
        )

        output = run(cmd, cwd=repo_dir)

        if not output:
            return ["No commits found."]

        commits = output.splitlines()

    filtered = [
        c for c in commits
        if not (
            c.startswith("Merge branch")
            or c.startswith("Merge pull request")
        )
    ]

    return filtered if filtered else ["No commits found."]

# ---------------------------------------------------------
# Generate synthesized release summary
# ---------------------------------------------------------

NOISE_PATTERNS = [
    r"^merge\b",
    r"^merge pull request\b",
    r"^merge branch\b",
    r"^merged pr\b",
    r"\brebase\b",
    r"\bmerge resolution\b",
    r"^wip\b",
    r"\bformatting\b",
    r"\bformat\b",
    r"\blinting\b",
    r"\btypo\b",
    r"\bdocstring\b",
    r"\bcomment\b",
    r"^add todo\b",
    r"^revise todo\b",
    r"^update todo\b",
]

SUMMARY_THEME_RULES = [
    {
        "theme": "ewts",
        "keywords": ["ewts", "nwm-ewts", "logging", "logger", "log_error", "log_critical"],
        "sentence": "Integrated EWTS logging support and updated logging behavior across components.",
        "priority": 90,
    },
    {
        "theme": "serialization",
        "keywords": [
            "serialization", "serialize", "serialized", "deserialize", "deserialization",
            "serialization_size", "state type", "state saving", "state restore",
            "state restoration", "reset_time", "reset time", "warm start", "restart"
        ],
        "sentence": "Updated state serialization, deserialization, reset-time, and restart handling.",
        "priority": 95,
    },
    {
        "theme": "hindcast",
        "keywords": ["hindcast", "hindcasting", "single t0", "lead time", "lead times"],
        "sentence": "Added and refined hindcast verification workflows and lead-time handling.",
        "priority": 85,
    },
    {
        "theme": "verification",
        "keywords": ["verification", "verify", "metrics", "metric", "paired dataframe", "observation", "obs", "usgs", "txdot", "evaluation", "plots", "plot"],
        "sentence": "Expanded verification, metric calculation, observation retrieval, and plotting capabilities.",
        "priority": 84,
    },
    {
        "theme": "forcing",
        "keywords": ["forcing", "aorc", "hrrr", "rap", "gfs", "nbm", "ana", "mrb", "short range", "medium range", "lagged ensemble", "forecastinputhorizons"],
        "sentence": "Updated forcing configuration, forecast product, and ensemble workflow support.",
        "priority": 82,
    },
    {
        "theme": "nhf",
        "keywords": ["nhf", "ngen hydrofabric", "hydrofabric", "hyfab", "gpkg", "geopackage", "vpu", "oconus", "crosswalk"],
        "sentence": "Added NHF, hydrofabric, geopackage, VPU, and crosswalk workflow updates.",
        "priority": 83,
    },
    {
        "theme": "bmi",
        "keywords": ["bmi", "bmi_model", "inputforcings", "model class", "get_value", "get_bound", "bmi calculation"],
        "sentence": "Refactored BMI model interfaces and related input-forcing behavior.",
        "priority": 80,
    },
    {
        "theme": "geospatial",
        "keywords": ["geometa", "geo_meta", "geogrid", "mesh", "crs", "bounds", "slope", "longitude_grid", "regrid", "regridding", "domain", "gage", "gages"],
        "sentence": "Updated geospatial metadata, regridding, domain, and gage handling.",
        "priority": 78,
    },
    {
        "theme": "model_outputs",
        "keywords": ["output", "rain+melt", "rainmelt", "rain melt", "giuh", "ponded depth", "channel inflow", "sac-sma", "sacsma", "cfe", "snow-17", "snow17", "sft", "smp", "noahowp"],
        "sentence": "Updated hydrologic model outputs, model coupling, and model-specific runtime behavior.",
        "priority": 86,
    },
    {
        "theme": "configuration",
        "keywords": ["config", "configuration", "realization", "yaml", "template", "settings", "input.config", "sample config"],
        "sentence": "Refined configuration, realization, and template generation behavior.",
        "priority": 76,
    },
    {
        "theme": "memory_cache",
        "keywords": ["cache", "cached", "lazy loading", "memory", "dataset", "xarray", "netcdf", "tmp", "temporary", "scratch", "close dataset", "locked", "s3"],
        "sentence": "Updated cache, dataset, temporary-file, and data-access handling.",
        "priority": 74,
    },
    {
        "theme": "testing",
        "keywords": ["test", "tests", "pytest", "expected results", "unit test", "unittest", "assert", "fixtures", "tolerance", "conftest"],
        "sentence": "Expanded automated test coverage and expected-result validation.",
        "priority": 72,
    },
    {
        "theme": "cicd",
        "keywords": ["ci", "cicd", "ci/cd", "pipeline", "github action", "gha", "trigger-ngen", "trivy", "customer delivery"],
        "sentence": "Updated CI/CD, security scanning, and downstream pipeline workflows.",
        "priority": 70,
    },
    {
        "theme": "docker_build",
        "keywords": ["docker", "dockerfile", "build", "pyproject", "dependency", "package", "site-packages"],
        "sentence": "Updated Docker, packaging, and dependency configuration.",
        "priority": 68,
    },
    {
        "theme": "validation_errors",
        "keywords": ["pydantic", "validation", "validate", "warning", "error", "exception", "traceback", "contenttypeerror", "permission"],
        "sentence": "Improved validation, warning, exception, and error-reporting behavior.",
        "priority": 66,
    },
    {
        "theme": "unit_conversion",
        "keywords": ["unit", "units", "conversion", "convert", "byte", "bytes", "ints", "integer", "float time"],
        "sentence": "Corrected unit conversions and size/type reporting.",
        "priority": 88,
    },
    {
        "theme": "cleanup_refactor",
        "keywords": ["refactor", "rename", "remove duplicate", "remove unused", "cleanup", "clean up", "simplify", "dry", "type hints", "imports"],
        "sentence": "Refactored and cleaned up implementation details across the codebase.",
        "priority": 50,
    },
]

def cleanup_commit_text(commit):
    """
    Clean a commit subject only for release-note synthesis.

    The raw Commit section does not use this function.
    """
    commit = re.sub(r"\s*\([0-9a-f]+\)$", "", commit)
    commit = re.sub(r"^\[[^\]]+\]\s*", "", commit)
    commit = re.sub(
        r"^(feat|fix|refactor|docs|test|build|ci|perf|style):\s*",
        "",
        commit,
        flags=re.IGNORECASE
    )
    return commit.strip()

def is_noisy_commit(commit):
    lower = cleanup_commit_text(commit).lower()

    return any(re.search(pattern, lower) for pattern in NOISE_PATTERNS)

def normalized_commit_lines(commits):
    lines = []

    for raw_commit in commits:
        if raw_commit in ["No commits found.", "No changes."]:
            continue

        for commit_line in str(raw_commit).splitlines():
            commit_line = cleanup_commit_text(commit_line.strip())

            if commit_line and not is_noisy_commit(commit_line):
                lines.append(commit_line)

    return lines

def matching_summary_themes(commit):
    lower = commit.lower()
    matches = []

    for rule in SUMMARY_THEME_RULES:
        if any(keyword in lower for keyword in rule["keywords"]):
            matches.append(rule)

    return matches

def select_summary_themes(commits, max_themes=5):
    """
    Classify commits into high-level release-note themes.

    Themes are scored by frequency and priority. This avoids dropping meaningful
    work merely because it did not match a small Additions/Removals/Changes
    bucket or because fallback items were capped.
    """
    theme_scores = {}

    for commit in normalized_commit_lines(commits):
        for rule in matching_summary_themes(commit):
            key = rule["theme"]

            if key not in theme_scores:
                theme_scores[key] = {
                    "rule": rule,
                    "count": 0,
                }

            theme_scores[key]["count"] += 1

    ranked = sorted(
        theme_scores.values(),
        key=lambda hit: (hit["count"], hit["rule"]["priority"]),
        reverse=True
    )

    selected = [hit["rule"] for hit in ranked[:max_themes]]

    # Present the selected themes in a stable, customer-friendly order rather
    # than strict frequency order.
    priority_order = {rule["theme"]: i for i, rule in enumerate(SUMMARY_THEME_RULES)}
    selected.sort(key=lambda rule: priority_order[rule["theme"]])

    return selected

def generate_release_summary(commits):
    """
    Generate a single concise, customer-facing release-note paragraph.

    Style goals:
    - single paragraph
    - describe what changed, not the motivation
    - consolidate related commits into high-level themes
    - exclude merge, formatting, typo, comment, and other low-value commits
    - avoid explanatory phrases such as "to improve" and "to support"
    """
    if commits in (["No commits found."], ["No changes."]):
        return commits[0]

    selected_themes = select_summary_themes(commits)

    if not selected_themes:
        return "Updated implementation details and corrected issues identified during release preparation."

    sentences = [rule["sentence"] for rule in selected_themes]

    # Keep the generated summary readable and concise. With the current sentence
    # templates, five themes generally lands around 75-125 words.
    return " ".join(sentences)


# ---------------------------------------------------------
# Generate Additions / Removals / Changes sections
# ---------------------------------------------------------

SECTION_ORDER = ["Additions", "Removals", "Changes"]

SECTION_THEME_RULES = [
    {
        "section": "Additions",
        "theme": "ewts",
        "keywords": ["ewts", "nwm-ewts", "logging", "logger", "log_error", "log_critical"],
        "summary": "Integrated EWTS logging support across affected components, including module-specific logging updates, optional logging behavior, Docker/build integration, and unit-test coverage where applicable.",
    },
    {
        "section": "Additions",
        "theme": "state_save_restore",
        "keywords": ["reset_time", "reset time", "state saving", "state restore", "state restoration", "warm start", "restart", "hindcast"],
        "summary": "Added state saving, state restoration, reset-time, restart, and hindcast workflow capabilities, including related time-management updates and model restart handling.",
    },
    {
        "section": "Additions",
        "theme": "serialization",
        "keywords": ["serialization", "serialize", "serialized", "deserialize", "deserialization", "serialization_size", "state type", "state size", "serialized size", "size messaging", "header"],
        "summary": "Implemented and expanded serialization support, including serialized size metadata, message constants, integer-based transfer structures, deserialization bounds handling, and state-transfer messaging.",
    },
    {
        "section": "Additions",
        "theme": "verification",
        "keywords": ["verification", "verify", "metrics", "metric", "observation", "obs", "usgs", "txdot", "evaluation", "plots", "plot"],
        "summary": "Expanded verification and evaluation capabilities with additional metric calculation behavior, observation retrieval support, plotting updates, gage-source integration, and forecast-to-observation alignment.",
    },
    {
        "section": "Additions",
        "theme": "forcing",
        "keywords": ["forcing", "aorc", "hrrr", "rap", "gfs", "nbm", "ana", "mrb", "short range", "medium range", "lagged ensemble", "forecastinputhorizons"],
        "summary": "Added and expanded forcing workflow support, including updated configuration templates, forecast product handling, lagged-ensemble inputs, regional forcing behavior, and package-delivered forcing resources.",
    },
    {
        "section": "Additions",
        "theme": "nhf_hydrofabric",
        "keywords": ["nhf", "ngen hydrofabric", "hydrofabric", "hyfab", "gpkg", "geopackage", "vpu", "oconus", "crosswalk"],
        "summary": "Added NHF, hydrofabric, geopackage, VPU, and crosswalk workflow capabilities, including utility scripts, oCONUS handling, and domain/gage data integration.",
    },
    {
        "section": "Additions",
        "theme": "model_coupling",
        "keywords": ["couple", "coupling", "sac-sma", "sacsma", "smp", "soil moisture profiles"],
        "summary": "Added hydrologic model coupling capabilities, including SAC-SMA and Soil Moisture Profiles integration where present in the commit set.",
    },
    {
        "section": "Additions",
        "theme": "testing",
        "keywords": ["test", "tests", "pytest", "expected results", "unit test", "unittest", "assert", "fixtures", "tolerance", "conftest"],
        "summary": "Expanded automated testing coverage, expected-result data, unit-test support, tolerance-based comparisons, serialization checks, and CI-exercised validation paths.",
    },
    {
        "section": "Removals",
        "theme": "removed_unused",
        "keywords": ["remove unused", "removed unused", "remove duplicate", "removed duplicate", "obsolete", "deprecated", "remove old", "removed old", "remove commented", "removed commented", "remove generic", "removed generic"],
        "summary": "Removed unused, duplicate, obsolete, and deprecated code paths, including stale helper functions, duplicated definitions, older EWTS references, and no-longer-needed implementation artifacts.",
    },
    {
        "section": "Removals",
        "theme": "removed_debug",
        "keywords": ["remove debug", "removed debug", "debug statements", "remove print", "removed print", "log noise", "testing code"],
        "summary": "Removed debug output, temporary testing code, unnecessary runtime messages, and related log noise from operational paths.",
    },
    {
        "section": "Removals",
        "theme": "removed_dependencies_or_assets",
        "keywords": ["remove dependency", "removed dependency", "drop dependency", "netcdf4 dependency", "remove coastal", "removed coastal", "large netcdf", "sfincs"],
        "summary": "Removed obsolete dependencies, unused generated assets, coastal/SFINCS build artifacts, and other files no longer needed in the release deliverables.",
    },
    {
        "section": "Changes",
        "theme": "serialization",
        "keywords": ["serialization", "serialize", "serialized", "deserialize", "deserialization", "serialization_size", "state type", "state size", "serialized size", "size messaging", "header"],
        "summary": "Reworked serialization behavior, message metadata, reported state types, size calculations, buffer validation, and transfer logic for state save and restore workflows.",
    },
    {
        "section": "Changes",
        "theme": "unit_conversion",
        "keywords": ["unit", "units", "conversion", "convert", "byte", "bytes", "ints", "integer", "float time"],
        "summary": "Corrected unit conversions and size/type reporting across model calculations, serialized buffers, time-step handling, and BMI-facing data exchanges.",
    },
    {
        "section": "Changes",
        "theme": "bmi",
        "keywords": ["bmi", "bmi_model", "inputforcings", "model class", "get_value", "get_bound", "bmi calculation", "bmi model"],
        "summary": "Refactored BMI model interfaces and input-forcing behavior, including model-class selection, getter/setter behavior, bounds handling, and BMI calculation fixes.",
    },
    {
        "section": "Changes",
        "theme": "geospatial",
        "keywords": ["geometa", "geo_meta", "geogrid", "mesh", "crs", "bounds", "slope", "longitude_grid", "regrid", "regridding", "domain", "gage", "gages"],
        "summary": "Updated geospatial metadata, regridding, CRS, mesh/geogrid, domain, gage, and crosswalk handling across forcing, verification, and realization workflows.",
    },
    {
        "section": "Changes",
        "theme": "model_outputs",
        "keywords": ["output", "rain+melt", "rainmelt", "rain melt", "giuh", "ponded depth", "channel inflow", "cfe", "snow-17", "snow17", "sft", "noahowp", "sac-sma", "sacsma", "smp"],
        "summary": "Updated hydrologic model outputs and model-specific runtime behavior, including formulation outputs, GIUH/channel-inflow values, ponded-depth variables, and model-specific state/runtime handling.",
    },
    {
        "section": "Changes",
        "theme": "configuration",
        "keywords": ["config", "configuration", "realization", "yaml", "template", "settings", "input.config", "sample config"],
        "summary": "Refined configuration, realization, template, sample-config, and package-resource handling across supported workflows and deployment environments.",
    },
    {
        "section": "Changes",
        "theme": "memory_cache",
        "keywords": ["cache", "cached", "lazy loading", "memory", "dataset", "xarray", "netcdf", "tmp", "temporary", "scratch", "close dataset", "locked", "s3"],
        "summary": "Updated cache, dataset, temporary-file, scratch-directory, and data-access behavior, including lazy loading, explicit dataset closure, retry handling, and local/S3 access refinements.",
    },
    {
        "section": "Changes",
        "theme": "cicd",
        "keywords": ["ci", "cicd", "ci/cd", "pipeline", "github action", "gha", "trigger-ngen", "trivy", "customer delivery"],
        "summary": "Updated CI/CD, security scanning, downstream pipeline triggers, and customer-delivery workflow configuration.",
    },
    {
        "section": "Changes",
        "theme": "docker_build",
        "keywords": ["docker", "dockerfile", "build", "pyproject", "dependency", "package", "site-packages"],
        "summary": "Updated Docker, build, packaging, dependency, and installed-resource configuration.",
    },
    {
        "section": "Changes",
        "theme": "validation_errors",
        "keywords": ["pydantic", "validation", "validate", "warning", "error", "exception", "traceback", "contenttypeerror", "permission"],
        "summary": "Improved validation, warning, exception, traceback, permission, and user-facing error-reporting behavior.",
    },
    {
        "section": "Changes",
        "theme": "cleanup_refactor",
        "keywords": ["refactor", "rename", "cleanup", "clean up", "simplify", "dry", "type hints", "imports", "property", "cached_property"],
        "summary": "Refactored and cleaned up implementation details, including naming consistency, type hints, imports, property handling, and internal helper structure.",
    },
]

ACTION_PREFIXES = {
    "Additions": "Added",
    "Removals": "Removed",
    "Changes": "Updated",
}

def classify_fallback_section(commit):
    lower = commit.lower()

    removal_keywords = [
        "remove", "removed", "delete", "deleted", "drop", "dropped",
        "deprecate", "deprecated", "eliminate"
    ]

    addition_keywords = [
        "add", "added", "introduce", "introduced", "create", "created",
        "implement", "implemented", "support", "enable", "new"
    ]

    if any(k in lower for k in removal_keywords):
        return "Removals"

    if any(k in lower for k in addition_keywords):
        return "Additions"

    return "Changes"

def summarize_fallback_commit(commit):
    """
    Convert one unmatched commit subject into a concise release-note phrase.

    This is intentionally short because fallback items are rolled up into a
    broader section sentence instead of emitted one-for-one as commit bullets.
    """
    text = cleanup_commit_text(commit)
    text = re.sub(r"\s*#\d+\b", "", text)
    text = re.sub(r"\s+", " ", text).strip()

    replacements = [
        (r"^fix(ed|es)?\b", "fixes for"),
        (r"^bug fixes?\b", "bug fixes for"),
        (r"^refactor(ed|s)?\b", "refactoring of"),
        (r"^improve(d|s)?\b", "improvements to"),
        (r"^update(d|s)?\b", "updates to"),
        (r"^change(d|s)?\b", "changes to"),
        (r"^remove(d|s)?\b", "removal of"),
        (r"^add(ed|s)?\b", "additions for"),
        (r"^implement(ed|s)?\b", "implementation of"),
    ]

    for pattern, replacement in replacements:
        if re.search(pattern, text, flags=re.IGNORECASE):
            text = re.sub(pattern, replacement, text, count=1, flags=re.IGNORECASE)
            break

    return text.strip(" .")

def matching_section_themes(commit):
    lower = commit.lower()
    matches = []

    for rule in SECTION_THEME_RULES:
        if any(keyword in lower for keyword in rule["keywords"]):
            matches.append(rule)

    return matches

def _append_unique(items, value):
    if value and value not in items:
        items.append(value)

def build_section_details(commits, max_fallback_examples_per_section=5):
    """
    Classify commits into Additions, Removals, and Changes with enough detail
    to create prose release-note summaries for each section.
    """
    details = {
        section: {
            "themes": [],
            "fallback": [],
        }
        for section in SECTION_ORDER
    }

    for commit_line in normalized_commit_lines(commits):
        matches = matching_section_themes(commit_line)

        if matches:
            for rule in matches:
                _append_unique(details[rule["section"]]["themes"], rule["summary"])
            continue

        section = classify_fallback_section(commit_line)
        fallback = summarize_fallback_commit(commit_line)
        _append_unique(details[section]["fallback"], fallback)

    for section in SECTION_ORDER:
        details[section]["fallback"] = details[section]["fallback"][:max_fallback_examples_per_section]

    return details

def _fallback_rollup_sentence(section, fallback_items):
    if not fallback_items:
        return None

    action = ACTION_PREFIXES[section]

    if len(fallback_items) == 1:
        joined = fallback_items[0]
    elif len(fallback_items) == 2:
        joined = " and ".join(fallback_items)
    else:
        joined = ", ".join(fallback_items[:-1]) + f", and {fallback_items[-1]}"

    return f"{action} additional release updates covering {joined}."

def generate_pr_sections(commits):
    """
    Generate Additions, Removals, and Changes as fuller release-note summaries.

    This does not simply categorize commits. It groups matching commits into
    meaningful themes, summarizes the work associated with each section, and
    rolls unmatched but relevant commits into an additional summary sentence.
    """
    details = build_section_details(commits)
    sections = {}

    for section in SECTION_ORDER:
        sentences = []

        for summary in details[section]["themes"]:
            _append_unique(sentences, summary)

        fallback_sentence = _fallback_rollup_sentence(section, details[section]["fallback"])
        _append_unique(sentences, fallback_sentence)

        if sentences:
            sections[section] = sentences

    return sections

def append_release_note_section(lines, section_name, items, heading_prefix="###"):
    """
    Append a release-note section as concise prose.

    Each item is a fuller summary sentence for a group of related commits.
    Markdown output uses bullets for readability; text output uses the same
    bullet style so the sections remain easy to scan.
    """
    if not items:
        return

    if heading_prefix:
        lines.append(f"{heading_prefix} {section_name}")
    else:
        lines.append(section_name)

    lines.extend([f"- {item}" for item in items])
    lines.append("")

# ------------------------------------------------------------
# Generate markdown output
# ------------------------------------------------------------
def generate_markdown(repo_info):
    repo_dir = os.path.expanduser(repo_info["repo_directory"])
    release = repo_info["release"]
    prev = repo_info["previous_release_tag"]
    notes = repo_info["release_notes"]

    effective_release = find_latest_patch_tag(repo_dir, release)
    release_sha = get_tag_commit_hash(repo_dir, effective_release)

    title = repo_title(repo_dir)

    md = []
    md.append(f"## {title}")
    md.append(f"- **Release Notes**: {notes}")
    md.append(f"- **Configured Release Version**: `{release}`")
    md.append(f"- **Effective Release Version**: `{effective_release}`")
    md.append(f"- **Release Commit SHA**: `{release_sha}`")

    if prev:
        md.append(f"- **Previous Release**: `{prev}`\n")
    else:
        md.append(f"- **Previous Release**: `N/A`\n")

    commits = get_commit_messages(repo_dir, release, prev)
    summary = generate_release_summary(commits)

    md.append("### Summary")
    md.append(f"{summary}\n")

    pr_sections = generate_pr_sections(commits)

    for section_name, items in pr_sections.items():
        append_release_note_section(md, section_name, items, heading_prefix="###")

    md.append("### Commits")
    md.extend([f"- {c}" for c in commits])

    md.append("\n")

    return "\n".join(md)

# ------------------------------------------------------------
# Generate text output
# ------------------------------------------------------------
def generate_text(repo_info, output_file):
    repo_dir = os.path.expanduser(repo_info["repo_directory"])
    release = repo_info["release"]
    prev = repo_info["previous_release_tag"]
    notes = repo_info["release_notes"]

    effective_release = find_latest_patch_tag(repo_dir, release)
    release_sha = get_tag_commit_hash(repo_dir, effective_release)

    title = repo_title(repo_dir)

    lines = []
    lines.append("\n----------------------------------------")
    lines.append(f"{title}")
    lines.append("----------------------------------------")
    lines.append(f"  Release Notes: {notes}")
    lines.append(f"  Configured Release Tag: {release}")
    lines.append(f"  Effective Release Tag: {effective_release}")
    lines.append(f"  Release Commit SHA: {release_sha}")

    if prev:
        lines.append(f"  Previous Tag: {prev}")
    else:
        lines.append(f"  Previous Tag: N/A")

    commits = get_commit_messages(repo_dir, release, prev)
    summary = generate_release_summary(commits)

    lines.append("\nSummary")
    wrapped_summary = textwrap.fill(summary, width=80)
    lines.append(f"{wrapped_summary}\n")

    pr_sections = generate_pr_sections(commits)

    for section_name, items in pr_sections.items():
        append_release_note_section(lines, section_name, items, heading_prefix="")

    lines.append("Commits")
    lines.extend([f"- {c}" for c in commits])

    lines.append("\n")

    with open(output_file, "a") as f:
        f.write("\n".join(lines))

# ---------------------------------------------------------
# Insert Markdown Table of Contents
# ---------------------------------------------------------
def insert_markdown_toc(md_file):
    with open(md_file, "r") as f:
        lines = f.readlines()

    toc_entries = []

    for line in lines:
        if line.startswith("## "):
            heading = line.strip()[3:]

            if heading.lower() == "table of contents":
                continue

            anchor = heading.lower().replace(" ", "-")
            toc_entries.append(f"- [{heading}](#{anchor})")

    new_lines = []

    for line in lines:
        if line.strip() == "<!--TOC-->":
            new_lines.append("\n".join(toc_entries) + "\n\n")
        else:
            new_lines.append(line)

    with open(md_file, "w") as f:
        f.writelines(new_lines)

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Generate release notes for multiple git repositories.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument(
        "--config", "-c",
        required=True,
        help="JSON config file"
    )

    parser.add_argument(
        "--checkout-branch",
        default="ngwpc-release",
        help="Branch to checkout before fetch/pull"
    )

    group = parser.add_mutually_exclusive_group(required=True)

    group.add_argument("--output")
    group.add_argument("--output_md")
    group.add_argument("--output_txt")
    group.add_argument("--output_both")

    args = parser.parse_args()

    md_output_file = None
    txt_output_file = None

    if args.output_both:
        md_output_file = normalize_output_filename(args.output_both, "md")
        txt_output_file = normalize_output_filename(args.output_both, "txt")
    elif args.output:
        md_output_file = normalize_output_filename(args.output, "default")
    elif args.output_md:
        md_output_file = normalize_output_filename(args.output_md, "md")
    elif args.output_txt:
        txt_output_file = normalize_output_filename(args.output_txt, "txt")
    else:
        print("Error: No output option provided.")
        sys.exit(1)

    with open(args.config) as f:
        repos = json.load(f)

    all_md_sections = []

    if txt_output_file:
        with open(txt_output_file, "w") as f:
            f.write(f"Release Notes ({datetime.now().strftime('%Y-%m-%d')})\n")

    for repo in repos:
        repo_dir = os.path.expanduser(repo["repo_directory"])

        skip = repo.get("skip", False)

        if skip:
            print(f"Skipping {repo_title(repo_dir)}")
            continue

        print(f"==> Processing {repo_title(repo_dir)}")

        checkout_branch(repo_dir, args.checkout_branch)

        print("    Fetching latest branches and tags...")
        run("git fetch --all --tags --prune", cwd=repo_dir, check=True)

        print(f"    Pulling latest {args.checkout_branch}...")
        run(f"git pull origin {args.checkout_branch}", cwd=repo_dir)

        if txt_output_file:
            generate_text(repo, txt_output_file)

        if md_output_file:
            all_md_sections.append(generate_markdown(repo))

    if txt_output_file:
        print(f"Done — Text written to: {txt_output_file}")

    if md_output_file:
        with open(md_output_file, "w") as f:
            f.write(f"# Release Notes ({datetime.now().strftime('%Y-%m-%d')})\n\n")
            f.write("## Table of Contents\n")
            f.write("<!--TOC-->\n\n")
            f.write("\n\n".join(all_md_sections))

        insert_markdown_toc(md_output_file)

        print(f"Done — Markdown written to: {md_output_file}")

if __name__ == "__main__":
    main()
