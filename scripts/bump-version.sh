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

perl -0pi -e "s/pub const version = \"\Q$old\E\";/pub const version = \"\Q$new\E\";/" src/version.zig
perl -0pi -e "s/\.version = \"\Q$old\E\"/\.version = \"\Q$new\E\"/" build.zig.zon
rg -l "\b\Q$old\E\b" README.md docs wiki scripts .github 2>/dev/null | while IFS= read -r file; do
  perl -0pi -e "s/\b\Q$old\E\b/\Q$new\E/g" "$file"
done

printf 'loam version %s -> %s\n' "$old" "$new"
