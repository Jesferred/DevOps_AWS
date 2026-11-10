#!/usr/bin/env bash
# Prints the unix time of the earliest commit in this push (BEFORE..GITHUB_SHA),
# i.e. the start of DORA lead time. Falls back to the head commit.
# Needs a full-history checkout (fetch-depth: 0).
set -euo pipefail

first=""
if [[ -n "${BEFORE:-}" && ! "$BEFORE" =~ ^0+$ ]] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  first=$(git log --format=%ct "$BEFORE..$GITHUB_SHA" | sort -n | head -1)
fi
echo "${first:-$(git log -1 --format=%ct "$GITHUB_SHA")}"
