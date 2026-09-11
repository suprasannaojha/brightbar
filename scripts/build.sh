#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

VERSION=""
MAKE_ZIP=false

while [[ $# -gt 0 ]]
do
  case "$1" in
    --version)
      if [[ $# -lt 2 || -z "${2:-}" ]]
      then
        echo "error: --version requires X.Y.Z" >&2
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    --zip)
      MAKE_ZIP=true
      shift
      ;;
    *)
      echo "usage: $0 [--version X.Y.Z] [--zip]" >&2
      exit 1
      ;;
  esac
done

swift build -c release --arch arm64

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="${BIN_DIR}/BrightBar"
if [[ ! -f "${BIN}" ]]
then
  echo "error: release binary not found at ${BIN}" >&2
  exit 1
fi

APP="${ROOT}/build/BrightBar.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/BrightBar"
chmod +x "${APP}/Contents/MacOS/BrightBar"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' >"${APP}/Contents/PkgInfo"

ICON="${ROOT}/Resources/AppIcon.icns"
if [[ -f "${ICON}" ]]
then
  cp "${ICON}" "${APP}/Contents/Resources/AppIcon.icns"
fi

if [[ -n "${VERSION}" ]]
then
  plutil -replace CFBundleShortVersionString -string "${VERSION}" "${APP}/Contents/Info.plist"
  BUILD_NUMBER="$(git -C "${ROOT}" rev-list --count HEAD 2>/dev/null || true)"
  if [[ -z "${BUILD_NUMBER}" ]]
  then
    BUILD_NUMBER="1"
  fi
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "${IDENTITY}" ]]
then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if echo "${identities}" | grep -F "Developer ID Application" >/dev/null
  then
    IDENTITY="$(echo "${identities}" | grep -F "Developer ID Application" | head -n 1 | sed -n 's/.*"\(.*\)"/\1/p')"
  elif echo "${identities}" | grep -F "Apple Development" >/dev/null
  then
    IDENTITY="$(echo "${identities}" | grep -F "Apple Development" | head -n 1 | sed -n 's/.*"\(.*\)"/\1/p')"
  else
    IDENTITY="-"
  fi
fi
if [[ -z "${IDENTITY}" ]]
then
  IDENTITY="-"
fi

echo "Signing with identity: ${IDENTITY}"
# Notarization requires a secure timestamp from Apple's server; ad-hoc signatures cannot have one.
TIMESTAMP_FLAG="--timestamp"
if [[ "${IDENTITY}" == "-" ]]
then
  TIMESTAMP_FLAG="--timestamp=none"
fi
if ! codesign --force --deep --options runtime "${TIMESTAMP_FLAG}" --sign "${IDENTITY}" "${APP}"
then
  echo "warning: codesign with --options runtime failed; retrying without hardened runtime" >&2
  codesign --force --deep "${TIMESTAMP_FLAG}" --sign "${IDENTITY}" "${APP}"
fi

echo "Built ${APP}"
echo "Run it with:  open ${APP}"
echo "Install with: ./scripts/install.sh"
echo "Or copy:      cp -R \"${APP}\" /Applications/"

if [[ "${MAKE_ZIP}" == true ]]
then
  ZIP_VERSION="${VERSION}"
  if [[ -z "${ZIP_VERSION}" ]]
  then
    ZIP_VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP}/Contents/Info.plist")"
  fi
  ZIP="${ROOT}/build/BrightBar-${ZIP_VERSION}.zip"
  rm -f "${ZIP}"
  ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
  echo "Created ${ZIP}"
fi
