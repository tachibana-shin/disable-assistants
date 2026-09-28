#!/usr/bin/env bash
#
# Run by semantic-release (see release.config.cjs) right before the GitHub
# release is published:
#   1. sync the version in the Theos control file with the release tag
#   2. build the rootless package that gets attached to the release
#
# Usage: bash scripts/prepare-release.sh <version>

set -euo pipefail

version="${1:-${NEXT_VERSION:-}}"
if [ -z "$version" ]; then
	echo "usage: $0 <version>" >&2
	exit 1
fi

cd "$(dirname "$0")/.."

# -i.bak keeps this working on both GNU sed and BSD sed
sed -i.bak "s/^Version: .*/Version: $version/" control
rm -f control.bak
echo "control: Version: $version"

make package FINALPACKAGE=1
