#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "usage: $0 <version>"
    echo "example: $0 0.3.2"
    exit 1
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$REPO_ROOT"

# update version in build.zig.zon
sed -i "s/\.version = \".*\"/\.version = \"$VERSION\"/" build.zig.zon

# check if there are changes
if ! git diff --quiet build.zig.zon; then
    git add build.zig.zon
    git commit -m "chore: v$VERSION"
fi

# force tag (delete if exists)
git tag -d "v$VERSION" 2>/dev/null || true
git push rotko ":refs/tags/v$VERSION" 2>/dev/null || true

# create and push new tag
git tag "v$VERSION"
git push rotko
git push rotko "v$VERSION"

echo "released v$VERSION"
