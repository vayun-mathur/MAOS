#!/usr/bin/env bash
#
# build-ota.sh — generate signed OTA package(s) + channel metadata from a SIGNED
# target-files zip.
#
# Prerequisite: you already produced a signed target-files with your MAOS keys, e.g.
#
#   sign_target_files_apks -o -d "$KEYSDIR" \
#     out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip \
#     signed-$DEVICE-$BUILD.zip
#
# (see docs/BUILD_RUNBOOK.md). This script turns that into a full OTA, an optional
# incremental OTA, and the tiny channel-metadata file the Updater polls.
#
# Run inside the AOSP tree after `source build/envsetup.sh` so ota_from_target_files is
# on PATH (else it's at build/make/tools/releasetools/ota_from_target_files).
#
set -euo pipefail

DEVICE="" ; CHANNEL="stable" ; BUILD="" ; SIGNED_TF="" ; PREV_TF="" ; OLD_BUILD=""
KEYSDIR="" ; OUTDIR="out/maos-ota"

usage() {
    cat >&2 <<EOF
usage: build-ota.sh -d DEVICE -b BUILD -t SIGNED_TF -k KEYSDIR [options]
  -d DEVICE       device codename (e.g. shusky)
  -b BUILD        build number for the new build (e.g. 2026080900)
  -t SIGNED_TF    signed target-files zip for the new build
  -k KEYSDIR      dir holding releasekey.{pk8,x509.pem} (OTA signing key)
  -c CHANNEL      release channel (default: stable)
  -p PREV_TF      previous signed target-files (to also build an incremental)
  -o OLD_BUILD    previous build number (required with -p; used in the file name)
  -O OUTDIR       output dir (default: out/maos-ota)
EOF
    exit 2
}

while getopts "d:b:t:k:c:p:o:O:h" opt; do
    case "$opt" in
        d) DEVICE="$OPTARG" ;;
        b) BUILD="$OPTARG" ;;
        t) SIGNED_TF="$OPTARG" ;;
        k) KEYSDIR="$OPTARG" ;;
        c) CHANNEL="$OPTARG" ;;
        p) PREV_TF="$OPTARG" ;;
        o) OLD_BUILD="$OPTARG" ;;
        O) OUTDIR="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -n "$DEVICE" && -n "$BUILD" && -n "$SIGNED_TF" && -n "$KEYSDIR" ]] || usage
[[ -f "$SIGNED_TF" ]] || { echo "signed target-files not found: $SIGNED_TF" >&2; exit 1; }
[[ -f "$KEYSDIR/releasekey.pk8" ]] || { echo "releasekey not found in $KEYSDIR" >&2; exit 1; }
if [[ -n "$PREV_TF" && -z "$OLD_BUILD" ]]; then echo "-p requires -o OLD_BUILD" >&2; exit 1; fi

OTA_TOOL="ota_from_target_files"
command -v "$OTA_TOOL" >/dev/null || \
    OTA_TOOL="${ANDROID_BUILD_TOP:?source build/envsetup.sh}/build/make/tools/releasetools/ota_from_target_files"

mkdir -p "$OUTDIR"

FULL="$OUTDIR/$DEVICE-ota_update-$BUILD.zip"
echo ">> full OTA -> $FULL"
"$OTA_TOOL" -k "$KEYSDIR/releasekey" "$SIGNED_TF" "$FULL"

if [[ -n "$PREV_TF" ]]; then
    [[ -f "$PREV_TF" ]] || { echo "previous target-files not found: $PREV_TF" >&2; exit 1; }
    INC="$OUTDIR/$DEVICE-incremental-$OLD_BUILD-$BUILD.zip"
    echo ">> incremental OTA ($OLD_BUILD -> $BUILD) -> $INC"
    "$OTA_TOOL" -k "$KEYSDIR/releasekey" -i "$PREV_TF" "$SIGNED_TF" "$INC"
fi

# Channel metadata polled by the Updater at
#   https://ota.ma.vayunmathur.com/$DEVICE-$CHANNEL
# Format: "BUILD TIMESTAMP CHANNEL". Keep this in sync with what your Updater fork
# parses (see updater/README.md).
META="$OUTDIR/$DEVICE-$CHANNEL"
printf '%s %s %s\n' "$BUILD" "$(date +%s)" "$CHANNEL" > "$META"
echo ">> metadata -> $META ($(cat "$META"))"

echo
echo "Artifacts in $OUTDIR — publish with ota/publish-ota.sh"
