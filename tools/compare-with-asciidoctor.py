#!/usr/bin/env python3
# Copyright (C) 2026 Osvaldo Santana Neto
# SPDX-License-Identifier: AGPL-3.0-only
"""Compares this parser against Asciidoctor over a corpus of AsciiDoc files.

Asciidoctor is the de facto reference where the specification is silent, so
disagreements are worth looking at — in either direction. Sometimes this parser
is wrong; sometimes the mapping in asciidoctor-oracle.rb is; occasionally
Asciidoctor is doing something the specification does not ask for.

Structure only. Asciidoctor's sourcemap records the line a block starts on and
nothing else, so positions cannot be compared this way and are checked
separately against the TCK's own cases and the range invariants in the test
suite.

    tools/compare-with-asciidoctor.py FILE_OR_DIRECTORY...
"""

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ADAPTER = ROOT / ".build" / "release" / "asciidoc-tck-adapter"
ORACLE = HERE / "asciidoctor-oracle.rb"

# Keys the oracle cannot fill in, or that carry no structure.
IGNORED = {"location", "delimiter", "marker", "attributes"}


def strip(node):
    """Reduces a graph to what the two sides can be compared on."""
    if isinstance(node, dict):
        return {
            key: strip(value) for key, value in sorted(node.items()) if key not in IGNORED
        }
    if isinstance(node, list):
        return [strip(item) for item in node]
    return node


def ours(source: str):
    request = json.dumps({"contents": source, "path": "-", "type": "block"})
    result = subprocess.run(
        [str(ADAPTER)], input=request, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"adapter failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def theirs(source: str):
    result = subprocess.run(
        ["ruby", str(ORACLE)], input=source, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"oracle failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def outline(node, depth=0, into=None):
    """A one-line-per-block sketch, which reads far better than a JSON diff."""
    if into is None:
        into = []
    if isinstance(node, dict) and node.get("type") == "block":
        label = node.get("name", "?")
        if "level" in node:
            label += f" {node['level']}"
        if "variant" in node:
            label += f" ({node['variant']})"
        into.append("  " * depth + label)
        depth += 1
    for key in ("blocks", "items"):
        for child in node.get(key, []) if isinstance(node, dict) else []:
            outline(child, depth, into)
    return into


def paths(arguments):
    for argument in arguments:
        path = Path(argument)
        if path.is_dir():
            yield from sorted(path.rglob("*.adoc"))
        else:
            yield path


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    if not ADAPTER.exists():
        sys.exit(f"build the adapter first: swift build -c release ({ADAPTER})")

    agreed = 0
    differed = []
    failed = []

    for path in paths(sys.argv[1:]):
        source = path.read_text(encoding="utf-8")
        try:
            mine, reference = ours(source), theirs(source)
        except RuntimeError as error:
            failed.append((path, str(error)))
            continue

        if strip(mine) == strip(reference):
            agreed += 1
        else:
            differed.append((path, mine, reference))

    for path, mine, reference in differed:
        print(f"── {path}")
        left, right = outline(mine), outline(reference)
        width = max((len(line) for line in left), default=0)
        print(f"   {'ours'.ljust(width)}   asciidoctor")
        for index in range(max(len(left), len(right))):
            a = left[index] if index < len(left) else ""
            b = right[index] if index < len(right) else ""
            mark = " " if a == b else "≠"
            print(f" {mark} {a.ljust(width)}   {b}")
        print()

    for path, error in failed:
        print(f"── {path}\n   {error}\n")

    total = agreed + len(differed) + len(failed)
    print(f"{agreed}/{total} agree · {len(differed)} differ · {len(failed)} failed")
    return 1 if differed or failed else 0


if __name__ == "__main__":
    sys.exit(main())
