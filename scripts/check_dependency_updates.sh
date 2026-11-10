#!/usr/bin/env bash
# Prints a markdown table of Swift packages and gems that have newer releases
# than the versions pinned in the repo. Read-only: it never changes any pin.
set -euo pipefail

RESOLVED="MFS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
rows=""

newer() { # true if $2 is a higher version than $1
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]
}

if [ -f "$RESOLVED" ]; then
  while IFS=$'\t' read -r name url version; do
    [ -z "$version" ] && continue # branch/revision pins have no version to compare
    latest=$(git ls-remote --tags --refs "$url" 2>/dev/null \
      | sed 's#.*refs/tags/##' \
      | grep -E '^v?[0-9]+(\.[0-9]+)*$' \
      | sed 's/^v//' | sort -V | tail -n1 || true)
    if [ -n "$latest" ] && newer "$version" "$latest"; then
      rows+="| Swift package | $name | $version | $latest |"$'\n'
    fi
  done < <(jq -r '.pins[] | [.identity, .location, (.state.version // "")] | @tsv' "$RESOLVED")
else
  echo "No Package.resolved found; skipping Swift packages." >&2
fi

if [ -f .gitmodules ]; then
  while read -r path; do
    url=$(git config -f .gitmodules "submodule.$path.url")
    pinned=$(git ls-tree HEAD "$path" | awk '{print $3}')
    upstream=$(git ls-remote "$url" HEAD | cut -f1)
    if [ -n "$pinned" ] && [ -n "$upstream" ] && [ "$pinned" != "$upstream" ]; then
      rows+="| Submodule | $path | ${pinned:0:7} | ${upstream:0:7} (default branch) |"$'\n'
    fi
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')
fi

if [ -f Gemfile.lock ]; then
  while read -r name current latest; do
    rows+="| Gem | $name | $current | $latest |"$'\n'
  done < <(bundle outdated --only-explicit --parseable 2>/dev/null \
    | sed -nE 's/^([^ ]+) \(newest ([^,]+), installed ([^,)]+).*/\1 \3 \2/p')
fi

if [ -n "$rows" ]; then
  printf '| Type | Name | Pinned | Latest |\n|---|---|---|---|\n%s' "$rows"
fi
