#!/usr/bin/env bash
# Releases version X.Y.Z from develop, following the git rules:
# release/X.Y.Z → main (--no-ff) + annotated tag vX.Y.Z → main back into develop, then pushes.
# The pushed tag starts .github/workflows/publish.yml, which publishes to pub.dev.
#
# Before running, describe the changes under "## Unreleased" at the top of CHANGELOG.md.
# Usage: tool/release.sh 0.3.2
set -euo pipefail

version="${1:?usage: tool/release.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]] || { echo "not a version: $version" >&2; exit 1; }
cd "$(dirname "$0")/.."

[[ "$(git branch --show-current)" == develop ]] || { echo "run it on develop" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "the working tree is not clean" >&2; exit 1; }
git fetch -q origin
[[ "$(git rev-parse develop)" == "$(git rev-parse origin/develop)" ]] || { echo "develop differs from origin/develop" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && { echo "tag v$version already exists" >&2; exit 1; }
[[ "$(head -n 1 CHANGELOG.md)" == "## Unreleased" ]] || { echo 'CHANGELOG.md must start with "## Unreleased"' >&2; exit 1; }

dart analyze --fatal-infos
dart test

git checkout -q -b "release/$version"
sed -i.bak "s/^version: .*/version: $version/" pubspec.yaml && rm pubspec.yaml.bak
sed -i.bak "1s/.*/## $version/" CHANGELOG.md && rm CHANGELOG.md.bak
dart pub publish --dry-run
git commit -qam "[RELEASE-$version] bump the version"

git checkout -q main
git merge -q --ff-only origin/main
git merge -q --no-ff "release/$version" -m "[RELEASE-$version] merge into main"
git tag -a "v$version" -m "v$version"
git checkout -q develop
git merge -q --no-ff main -m "[RELEASE-$version] merge main back into develop"

git push -q origin main develop "release/$version" "v$version"
echo "v$version pushed; GitHub Actions publishes it: https://github.com/revoockv/revoockv-audio-enhance/actions"
