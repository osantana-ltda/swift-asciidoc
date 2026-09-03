#!/bin/bash
# Runs the parser over a real book and reports what it makes of it.
#
# The fixtures in Tests/ are written by us, so they only ever contain what we
# already thought of. A book someone actually wrote and shipped contains what
# we did not — which is how the table-delimiter bug was found, where a table
# padded out to the width of its widest row swallowed the prose after it.
#
# Corpora are NOT vendored into this repository. Python Fluente, the corpus
# this was built against, is CC BY-NC-ND: fine to read and run against, not to
# redistribute or derive from, and its licence would not sit with this
# package's. So the corpus is whatever tree you point the script at.
#
#     git clone --depth 1 https://github.com/pythonfluente/pythonfluente2e
#     tools/corpus-check.sh pythonfluente2e
#
# Three things are checked, in order of how much they matter:
#
#   1. Round trip. Every file must come back byte-identical, except for the
#      two normalizations §6.2 documents. Any other difference is a defect.
#   2. Coverage. Every `unparsed` block is a construct the book uses and the
#      parser does not model. The count belongs in the backlog.
#   3. Census. What the book is actually made of, which is what says where
#      effort is worth spending.
set -euo pipefail

corpus=${1:-}
if [ -z "$corpus" ] || [ ! -d "$corpus" ]; then
    echo "usage: $0 <path to a checked-out book>" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
swift build -c release >/dev/null
adapter="$PWD/.build/release/asciidoc-tck-adapter"

files=$(find "$corpus" -name "*.adoc" -not -path "*/.git/*" | sort)
count=$(echo "$files" | grep -c "" || true)
echo "corpus: $count files, $(echo "$files" | xargs cat | grep -c "" || true) lines"
echo

# 1. Round trip, classifying each difference. A difference between a
#    whitespace-only line and an empty one is the documented normalization;
#    anything else is not.
identical=0
normalized=0
broken=""
for file in $files; do
    if diff -q <("$adapter" --roundtrip <"$file") "$file" >/dev/null 2>&1; then
        identical=$((identical + 1))
        continue
    fi
    if diff <("$adapter" --roundtrip <"$file") "$file" | grep -E "^[<>]" \
        | grep -qvE "^[<>] *$"; then
        broken="$broken $file"
    else
        normalized=$((normalized + 1))
    fi
done

echo "round trip: $identical identical, $normalized differing only by the"
echo "            documented whitespace normalization"
if [ -n "$broken" ]; then
    echo
    echo "DIVERGED — these are defects:"
    for file in $broken; do
        echo "  ${file#"$corpus"/}"
    done
fi
echo

# 2 and 3. One pass over the trees for both.
census=$(for file in $files; do "$adapter" --tree <"$file"; done \
    | sed 's/^ *//' | sed 's/ .*//' | sort | uniq -c | sort -rn)

unparsed=$(echo "$census" | awk '$2 == "unparsed" { print $1 }')
echo "unmodelled constructs: ${unparsed:-0}"
echo
echo "what the book is made of:"
echo "$census" | grep -vE "^ *[0-9]+ :" | head -25

[ -z "$broken" ] || exit 1
