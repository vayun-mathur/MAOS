#!/usr/bin/env bash
#
# publish-ota.sh — upload OTA artifacts to a PUBLIC GitHub Release so the OTA server
# (ota.ma.vayunmathur.com) can proxy them from `.../releases/latest/download/<file>`.
#
# The server serves whatever is on the LATEST release, so this marks the release latest.
# Devices download from our origin (the server proxies the bytes), never from GitHub
# directly, so a redirect-averse Updater still works.
#
# Requires the GitHub CLI (`gh`) authenticated with write access to the OTA repo.
#
# Usage:
#   ota/publish-ota.sh -r vayun-mathur/MAOS-releases -t 2026080900 -O out/maos-ota
#
set -euo pipefail

REPO="" ; TAG="" ; OUTDIR="out/maos-ota"

usage() {
    cat >&2 <<EOF
usage: publish-ota.sh -r OWNER/REPO -t TAG [-O OUTDIR]
  -r OWNER/REPO   PUBLIC GitHub repo to hold OTA releases (must match the server's
                  MAOS_OTA_GH; defaults there to vayun-mathur/MAOS)
  -t TAG          release tag (e.g. the build number 2026080900)
  -O OUTDIR       dir containing the artifacts from build-ota.sh (default: out/maos-ota)
EOF
    exit 2
}

while getopts "r:t:O:h" opt; do
    case "$opt" in
        r) REPO="$OPTARG" ;;
        t) TAG="$OPTARG" ;;
        O) OUTDIR="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -n "$REPO" && -n "$TAG" ]] || usage
command -v gh >/dev/null || { echo "gh (GitHub CLI) not found" >&2; exit 1; }
shopt -s nullglob
FILES=("$OUTDIR"/*.zip "$OUTDIR"/*-stable "$OUTDIR"/*-beta)
[[ ${#FILES[@]} -gt 0 ]] || { echo "no artifacts in $OUTDIR" >&2; exit 1; }

echo ">> publishing ${#FILES[@]} file(s) to $REPO @ $TAG (latest)"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "${FILES[@]}" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --latest
else
    gh release create "$TAG" "${FILES[@]}" \
        --repo "$REPO" \
        --title "MAOS OTA $TAG" \
        --notes "Automated MAOS OTA release." \
        --latest
fi

echo ">> done. Server will serve these from https://ota.ma.vayunmathur.com/<file>"
