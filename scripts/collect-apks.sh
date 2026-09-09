#!/usr/bin/env bash
#
# collect-apks.sh — populate vendor/modern-apps/prebuilts/ with the Modern Apps
# release APKs before an AOSP build.
#
# The APKs are git-ignored (large binaries, reproducible from the Modern-Apps repo),
# so this must run on the build host before `m`/`make`.
#
# Usage:
#   scripts/collect-apks.sh <path>
#
#   <path> may be:
#     - a Modern-Apps repo root      (looks in distribution_apks/ and each module's
#                                      build/outputs/apk/release/)
#     - a distribution_apks/ dir      (produced by Modern-Apps release.sh)
#     - any dir containing *-release.apk files
#
set -euo pipefail

SRC="${1:?usage: collect-apks.sh <path to Modern-Apps repo, its distribution_apks dir, or a dir of *-release.apk>}"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/prebuilts"
mkdir -p "$DEST"

# The app list is the one in build-maos.sh, parsed rather than duplicated. These two
# arrays drifted apart once already (22 vs 18), and the symptom was a Soong failure about
# a missing prebuilt rather than anything pointing back at this script.
BUILD_MAOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build-maos.sh"
[[ -f "$BUILD_MAOS" ]] || { echo "ERROR: cannot find $BUILD_MAOS to read the app list" >&2; exit 1; }
mapfile -t APPS < <(sed -n 's/^APPS=(\(.*\))$/\1/p' "$BUILD_MAOS" | tr ' ' '\n' | grep -v '^$')
[[ "${#APPS[@]}" -gt 0 ]] || { echo "ERROR: could not parse APPS=(...) from $BUILD_MAOS" >&2; exit 1; }

find_apk() {
  local app="$1"
  local candidates=(
    "$SRC/${app}-release.apk"
    "$SRC/distribution_apks/${app}-release.apk"
    "$SRC/${app}/build/outputs/apk/release/${app}-release.apk"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

missing=0
for app in "${APPS[@]}"; do
  if apk="$(find_apk "$app")"; then
    cp -v "$apk" "$DEST/${app}-release.apk"
  else
    echo "ERROR: could not find ${app}-release.apk under $SRC" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "One or more APKs were missing. Build them first (Modern-Apps: ./release.sh or per-module :<app>:assembleRelease)." >&2
  exit 1
fi

echo "Done. Copied ${#APPS[@]} APKs into $DEST"
