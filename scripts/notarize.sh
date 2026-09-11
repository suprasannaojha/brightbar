#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

usage() {
  echo "usage: $0 <path-to-zip>" >&2
}

print_credential_help() {
  local profile="${NOTARY_PROFILE:-brightbar}"
  cat >&2 <<EOF

No notarization credentials found.

Create a keychain profile (recommended, once per Mac):

  xcrun notarytool store-credentials "${profile}" \\
    --apple-id "you@example.com" \\
    --team-id "YOUR_TEAM_ID" \\
    --password "app-specific-password"

The app-specific password is created at https://appleid.apple.com (Sign-In and Security → App-Specific Passwords).
Override the profile name with NOTARY_PROFILE (default: brightbar).

Or set environment variables and re-run:

  export APPLE_ID="you@example.com"
  export TEAM_ID="YOUR_TEAM_ID"
  export APP_PASSWORD="app-specific-password"

Then:

  $0 <path-to-zip>

EOF
}

if [[ $# -lt 1 ]]
then
  usage
  exit 1
fi

ZIP_ARG="$1"
if [[ "${ZIP_ARG}" == /* ]]
then
  ZIP="${ZIP_ARG}"
else
  ZIP="$(pwd)/${ZIP_ARG}"
fi

if [[ ! -f "${ZIP}" ]]
then
  echo "error: zip not found: ${ZIP}" >&2
  exit 1
fi

PROFILE="${NOTARY_PROFILE:-brightbar}"
HAVE_ENV=0
if [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]
then
  HAVE_ENV=1
fi

if [[ "${HAVE_ENV}" -eq 0 ]]
then
  if ! xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1
  then
    print_credential_help
    exit 1
  fi
fi

echo "Submitting ${ZIP} to Apple notary service..."
if [[ "${HAVE_ENV}" -eq 1 ]]
then
  xcrun notarytool submit "${ZIP}" --wait --apple-id "${APPLE_ID}" --team-id "${TEAM_ID}" --password "${APP_PASSWORD}"
else
  xcrun notarytool submit "${ZIP}" --wait --keychain-profile "${PROFILE}"
fi

APP="${ROOT}/build/BrightBar.app"
if [[ ! -d "${APP}" ]]
then
  echo "BrightBar.app not in build/; unpacking zip for stapling..."
  mkdir -p "${ROOT}/build"
  ditto -x -k "${ZIP}" "${ROOT}/build"
fi
if [[ ! -d "${APP}" ]]
then
  echo "error: BrightBar.app not found at ${APP} after unpacking ${ZIP}" >&2
  exit 1
fi

echo "Stapling notarization ticket to ${APP}"
xcrun stapler staple "${APP}"

echo "Re-zipping stapled app to ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

echo "Notarized, stapled, and re-zipped: ${ZIP}"
