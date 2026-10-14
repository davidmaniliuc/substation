#!/bin/bash
# Tags HEAD as the next release and pushes the tag, which is what publishes
# it (.github/workflows/release.yml, docs/RELEASING.md).
#
#   tools/release.sh            next patch in the current series: v0.9.0, v0.9.1, ...
#   tools/release.sh 0.10       start a new series at v0.10.0
#   tools/release.sh 1.0.0      exactly this version
#
# The current series is the newest release tag's, or the project's
# MARKETING_VERSION before the first release. Nothing is pushed until the
# tag is confirmed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

fail() { echo "error: $*" >&2; exit 1; }

[ "$(git rev-parse --abbrev-ref HEAD)" = master ] || fail "releases are cut from master"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "the working tree has uncommitted changes"
git fetch -q --tags origin master
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] \
    || fail "HEAD is not origin/master; push (or pull) first, so the tag names a commit GitHub has"
if tag="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null)"; then
    fail "HEAD is already released as $tag"
fi

latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"
latest="${latest#v}"

case "${1:-}" in
    "")
        if [ -n "$latest" ]; then
            version="${latest%.*}.$(( ${latest##*.} + 1 ))"
        else
            version="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' ps1-macos/PS1.xcodeproj/project.pbxproj | head -1)"
        fi
        ;;
    *.*.*) version="$1" ;;
    *.*) version="$1.0" ;;
    *) fail "give a series (0.10) or a version (1.0.0), not '$1'" ;;
esac

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$version' is not MAJOR.MINOR.PATCH"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "v$version already exists"
if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
    fail "v$version would sort before the latest release, v$latest"
fi

commit="$(git rev-parse --short=7 HEAD)"
build="$(git rev-list --count HEAD)"
echo "Release Substation $version (build $build, $commit): $(git log -1 --format=%s)"
read -r -p "Tag v$version and push it? [y/N] " answer
[ "$answer" = y ] || [ "$answer" = Y ] || fail "nothing tagged"

git tag -a "v$version" -m "Substation $version"
git push origin "v$version"
echo "==> pushed v$version; the release workflow is building it:"
echo "    https://github.com/davidmaniliuc/substation/actions/workflows/release.yml"
