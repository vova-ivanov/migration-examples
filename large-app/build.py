#!/usr/bin/env python3
"""
build.py - Merges component YAML files into a single CloudFormation template.

Uses text-based extraction to preserve CloudFormation intrinsic function tags
like !Ref, !Sub, !GetAtt, !If without mangling them through a YAML parser.
"""

import os
import re
import sys

COMPONENTS_DIR = os.path.join(os.path.dirname(__file__), "components")
HEADER_FILE = os.path.join(COMPONENTS_DIR, "_header.yaml")
OUTPUT_FILE = os.path.join(os.path.dirname(__file__), "large-app.yaml")


def extract_section(lines, section_name):
    """
    Extract content of a top-level YAML section by text scanning.

    Looks for a line matching ^SectionName: (at column 0)
    then collects all subsequent indented (or blank/comment-only) lines
    until a new non-indented, non-blank, non-comment line appears.

    Returns a list of raw lines (without trailing newline) that form the
    section body (i.e. everything AFTER the section header line itself).
    """
    in_section = False
    collected = []

    for line in lines:
        stripped = line.rstrip("\n")

        # Detect section header: starts at column 0, matches SectionName:
        if re.match(rf'^{re.escape(section_name)}(\s*:.*)?\s*$', stripped) or \
                stripped.startswith(f"{section_name}:"):
            # Only treat it as our section header if it's truly at column 0
            if re.match(rf'^{re.escape(section_name)}:', stripped):
                in_section = True
                continue  # skip the header line itself

        if in_section:
            # A new top-level key (non-indented, non-blank, non-comment) ends the section
            if stripped and not stripped.startswith(" ") and not stripped.startswith("\t") \
                    and not stripped.startswith("#"):
                # This is a new top-level section
                break
            collected.append(stripped)

    # Strip trailing blank lines
    while collected and not collected[-1].strip():
        collected.pop()

    return collected


def read_file_lines(path):
    with open(path, "r") as f:
        return f.readlines()


def count_resources_in_lines(lines):
    """Count top-level resource logical IDs inside a Resources section body."""
    count = 0
    for line in lines:
        # A resource logical ID is indented by exactly 2 spaces and followed by ':'
        if re.match(r'^  [A-Za-z][A-Za-z0-9]*:', line):
            count += 1
    return count


def main():
    # --- Read header ---
    if not os.path.exists(HEADER_FILE):
        print(f"ERROR: Header file not found: {HEADER_FILE}", file=sys.stderr)
        sys.exit(1)

    header_lines = read_file_lines(HEADER_FILE)
    header_text = "".join(header_lines)

    # --- Walk component files ---
    component_files = []
    for root, dirs, files in os.walk(COMPONENTS_DIR):
        # Sort dirs in-place for deterministic traversal
        dirs.sort()
        for fname in sorted(files):
            if not fname.endswith(".yaml"):
                continue
            fpath = os.path.join(root, fname)
            # Skip the header file
            if os.path.abspath(fpath) == os.path.abspath(HEADER_FILE):
                continue
            component_files.append(fpath)

    # Sort by path for deterministic ordering
    component_files.sort()

    all_resource_lines = []
    all_output_lines = []
    total_resources = 0

    print("Merging component files:")
    for fpath in component_files:
        rel = os.path.relpath(fpath, os.path.dirname(__file__))
        file_lines = read_file_lines(fpath)

        res_lines = extract_section(file_lines, "Resources")
        out_lines = extract_section(file_lines, "Outputs")

        res_count = count_resources_in_lines(res_lines)
        total_resources += res_count

        print(f"  {rel}  ({res_count} resources)")

        if res_lines:
            all_resource_lines.extend(res_lines)
            all_resource_lines.append("")  # blank separator between files

        if out_lines:
            all_output_lines.extend(out_lines)
            all_output_lines.append("")

    # --- Assemble output ---
    output_parts = [header_text.rstrip("\n")]

    output_parts.append("\nResources:")
    for line in all_resource_lines:
        output_parts.append(line)

    if all_output_lines:
        output_parts.append("\nOutputs:")
        for line in all_output_lines:
            output_parts.append(line)

    output_text = "\n".join(output_parts) + "\n"

    with open(OUTPUT_FILE, "w") as f:
        f.write(output_text)

    print(f"\nWrote: {OUTPUT_FILE}")
    print(f"Total resources: {total_resources}")


if __name__ == "__main__":
    main()
