#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK="${ROOT}/Casks/brightbar.rb"

usage() {
  echo "usage: $0 <version> <sha256>" >&2
}

if [[ $# -ne 2 ]]
then
  usage
  exit 1
fi

VERSION="$1"
SHA="$2"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]
then
  echo "error: version must look like X.Y.Z (got: ${VERSION})" >&2
  exit 1
fi
if [[ ! "${SHA}" =~ ^[0-9a-fA-F]{64}$ ]]
then
  echo "error: sha256 must be 64 hex characters" >&2
  exit 1
fi
if [[ ! -f "${CASK}" ]]
then
  echo "error: cask not found: ${CASK}" >&2
  exit 1
fi

tmp="$(mktemp)"
sed -E \
  -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
  -e "s/^  sha256 .*/  sha256 \"${SHA}\"/" \
  "${CASK}" >"${tmp}"
mv "${tmp}" "${CASK}"

echo "Updated ${CASK}"
echo "  version \"${VERSION}\""
echo "  sha256 \"${SHA}\""
