#!/usr/bin/env python3
import json
import os
import argparse
import subprocess
import sys
from pathlib import Path
from datetime import datetime
import textwrap

# ---------------------------------------------------------
# Normalize output filename
# ---------------------------------------------------------
def normalize_output_filename(filename: str, mode: str) -> str:
    """
    Normalize output filename based on mode:
    mode = "default" -> treat as Markdown unless extension is given
    mode = "md" -> ensure .md extension
    mode = "txt" -> ensure .txt extension
    """

    base, ext = os.path.splitext(filename)

    if mode == "default":
        # no extension → .md
        return filename if ext else f"{filename}.md"

    elif mode == "md":
        # enforce .md
        return f"{base}.md"

    elif mode == "txt":
        # enforce .txt
        return f"{base}.txt"

    else:
        raise ValueError(f"Unknown output mode: {mode}")

# ------------------------------------------------------------
# Generate markdown output
# ------------------------------------------------------------
def generate_markdown(repo_info):
    repo_dir = os.path.expanduser(repo_info["repo_directory"])
    release = repo_info["release"]
    prev = repo_info["previous_release_tag"]
    notes = repo_info["release_notes"]
    summary = repo_info["commit_summary"]

    title = repo_title(repo_dir)

    md = []
    md.append(f"## {title}")
    md.append(f"- **Release Notes**: {notes}")
    md.append(f"- **Release Version**: `{release}`")
    if prev:
        md.append(f"- **Previous Release**: `{prev}`\n")
    else:
        md.append(f"- **Previous Release**: `N/A`\n")

    commits = get_commit_messages(repo_dir, release, prev)

    md.append("### Summary")
    md.append(f"{summary}\n")

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
    summary = repo_info["commit_summary"]

    title = repo_title(repo_dir)

    lines = []
    lines.append("\n----------------------------------------")
    lines.append(f"{title}")
    lines.append("----------------------------------------")
    lines.append(f"  Release Notes: {notes}")
    lines.append(f"  Release Tag: {release}")
    if prev:
        lines.append(f"  Previous Tag: {prev}")
    else:
        lines.append(f"  Previous Tag: N/A")

    commits = get_commit_messages(repo_dir, release, prev)

    lines.append("\nSummary")
    wrapped_summary = textwrap.fill(summary, width=80)
    lines.append(f"{wrapped_summary}\n")

    lines.append("Commits")
    lines.extend([f"- {c}" for c in commits])

    lines.append("\n")

    with open(output_file, "a") as f:
        f.write("\n".join(lines))

# ---------------------------------------------------------
# Shell runner
# ---------------------------------------------------------
def run(cmd, cwd=None):
    result = subprocess.run(
        cmd, cwd=cwd, shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    if result.returncode != 0:
        print(f"! Command failed: {cmd}")
        print(result.stderr)
    return result.stdout.strip()


# ---------------------------------------------------------
# Extract commits
# ---------------------------------------------------------
def get_commit_messages(repo_dir, release, prev):
    # If no previous tag → get all commits up to release
    if not prev:
        cmd = (
            f"git log {release} "
            "--pretty=format:'%s (%h)'"
        )
        commits = run(cmd, cwd=repo_dir).split("\n")
    else:
        # Same tag → no changes
        if release == prev:
            return ["No changes."]

        cmd = (
            f"git log {prev}..{release} "
            "--pretty=format:'%s (%h)'"
        )
        output = run(cmd, cwd=repo_dir)
        if not output:
            return ["No commits found."]
        commits = output.split("\n")

    # Filter out merge commits
    filtered = [
        c for c in commits
        if not (
            c.startswith("Merge branch")
            or c.startswith("Merge pull request")
        )
    ]

    return filtered if filtered else ["No commits found."]


def repo_title(path):
    return Path(path).name

# ---------------------------------------------------------
# Insert Markdown Table of Contents at top of document
# ---------------------------------------------------------
def insert_markdown_toc(md_file):
    """Insert a TOC containing only repo titles (## headings)."""
    with open(md_file, "r") as f:
        lines = f.readlines()

    toc_entries = []

    for line in lines:
        # Match repo title headings:  ## RepoName
        if line.startswith("## "):
            heading = line.strip()[3:]  # remove "## "

            # Skip the main "Table of Contents" heading
            if heading.lower() == "table of contents":
                continue

            # Build anchor
            anchor = heading.lower().replace(" ", "-")
            toc_entries.append(f"- [{heading}](#{anchor})")

    # Replace placeholder
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

    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", help="Base output filename (default .md unless extension specified)")
    group.add_argument("--output_md", help="Output filename (forced .md)")
    group.add_argument("--output_txt", help="Output filename (forced .txt)")
    group.add_argument("--output_both", help="Base name for generating both .md and .txt outputs")

    args = parser.parse_args()
    
    # Determine output filename
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

    # Load config
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
        run("git pull", cwd=repo_dir)

        # Determine generator
        if txt_output_file:
            generate_text(repo, txt_output_file)

        if md_output_file:
            all_md_sections.append(generate_markdown(repo))

    if txt_output_file:
        print(f"✅ Done — Testfile written to: {txt_output_file}")
    if md_output_file:
        with open(md_output_file, "w") as f:
            f.write(f"# Release Notes ({datetime.now().strftime('%Y-%m-%d')})\n\n")
            f.write("## Table of Contents\n")
            f.write("<!--TOC-->\n\n")
            f.write("\n\n".join(all_md_sections))
        insert_markdown_toc(md_output_file)
        print(f"✅ Done — Markdown written to: {md_output_file}")

if __name__ == "__main__":
    main()

