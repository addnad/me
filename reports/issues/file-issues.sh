#!/usr/bin/env bash
# Files the six prepared issues on ritual-foundation/ritual-dapp-skills.
# Prerequisites: `gh` CLI authenticated as you (gh auth status).
# Run from anywhere: bash reports/issues/file-issues.sh
set -euo pipefail

REPO="ritual-foundation/ritual-dapp-skills"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in "$DIR"/0*.md; do
    title=$(grep -m1 '^\*\*Title:\*\* ' "$f" | sed 's/^\*\*Title:\*\* //')
    # body = everything after the "**Body:**" marker line
    body=$(awk 'found{print} /^\*\*Body:\*\*$/{found=1}' "$f")
    echo "Filing: $title"
    gh issue create -R "$REPO" --title "$title" --body "$body"
    echo
done
echo "All issues filed."
