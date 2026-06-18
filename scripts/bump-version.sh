#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <semver>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 64
fi

new="$1"
if ! printf '%s' "$new" | grep -Eq '^(0|[1-9][0-9]*)\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
  echo "version must be semver-ish: 0.1.0" >&2
  exit 65
fi

old=$(sed -n 's/pub const version = "\(.*\)";/\1/p' src/version.zig)
if [ -z "$old" ]; then
  echo "could not find version in src/version.zig" >&2
  exit 66
fi

export OLD_VERSION="$old"
export NEW_VERSION="$new"
perl -0pi -e 's/pub const version = "\Q$ENV{OLD_VERSION}\E";/pub const version = "\Q$ENV{NEW_VERSION}\E";/' src/version.zig
perl -0pi -e 's/\.version = "\Q$ENV{OLD_VERSION}\E"/\.version = "\Q$ENV{NEW_VERSION}\E"/' build.zig.zon

files=$(rg -l "\Q$old\E" README.md docs scripts .github 2>/dev/null || true)
for file in $files; do
  perl -0pi -e 's/\b\Q$ENV{OLD_VERSION}\E\b/\Q$ENV{NEW_VERSION}\E/g' "$file"
done

printf 'loam version %s -> %s\n' "$old" "$new"
