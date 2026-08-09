#!/usr/bin/env bash
#
# publish-ota.sh — upload OTA artifacts to Cloudflare R2.
#
# `ota.ma.vayunmathur.com` is an R2 bucket served directly via a Cloudflare custom
# domain, so devices download straight from R2 — there is no GitHub Release and no
# server proxy in the loop. An object stored at key `<file>` is served at
# `https://ota.ma.vayunmathur.com/<file>`, which is exactly what the Updater polls.
#
# Upload order matters: the signed zips go up FIRST and the channel-metadata pointer
# goes up LAST, so a device polling mid-publish never sees metadata referencing a zip
# that isn't there yet.
#
# R2 is S3-compatible, so this uses the standard `aws` CLI pointed at the R2 endpoint.
# Credentials come from the environment (never commit them):
#
#   R2_ACCESS_KEY_ID       R2 API token access key id
#   R2_SECRET_ACCESS_KEY   R2 API token secret
#   R2_ACCOUNT_ID          Cloudflare account id (used to build the endpoint), OR
#   R2_ENDPOINT            full endpoint URL (overrides R2_ACCOUNT_ID)
#   R2_BUCKET              bucket name (default: maos-ota, or pass -b)
#
# Requires: awscli v2.
#
set -euo pipefail

BUCKET="${R2_BUCKET:-maos-ota}"
OUTDIR="out/maos-ota"

usage() {
    cat >&2 <<EOF
usage: publish-ota.sh [-b BUCKET] [-O OUTDIR]
  -b BUCKET   R2 bucket name (default: \$R2_BUCKET or maos-ota)
  -O OUTDIR   dir containing the artifacts from build-ota.sh (default: out/maos-ota)

Required env: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and either R2_ACCOUNT_ID or
R2_ENDPOINT. See the header of this file.
EOF
    exit 2
}

while getopts "b:O:h" opt; do
    case "$opt" in
        b) BUCKET="$OPTARG" ;;
        O) OUTDIR="$OPTARG" ;;
        *) usage ;;
    esac
done

command -v aws >/dev/null || { echo "aws CLI (v2) not found" >&2; exit 1; }
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"

ENDPOINT="${R2_ENDPOINT:-}"
if [[ -z "$ENDPOINT" ]]; then
    : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID or R2_ENDPOINT}"
    ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi

# Map R2 creds to the AWS SDK's variables for this process only.
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
# R2 ignores region but the SDK requires one; "auto" is the documented value.
export AWS_DEFAULT_REGION="auto"
# aws-cli v2 adds trailing/streaming integrity checksums that break R2 multipart
# uploads (which is every multi-GB OTA). Only send checksums when the API requires
# them, matching Cloudflare's own R2 guidance.
export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"
export AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"

s3() { aws s3 --endpoint-url "$ENDPOINT" "$@"; }

put() {
    # put <local> <key> <content-type> <cache-control>
    local src="$1" key="$2" ctype="$3" cache="$4"
    echo ">> $key  ($(du -h "$src" | cut -f1), $ctype)"
    s3 cp "$src" "s3://$BUCKET/$key" \
        --content-type "$ctype" \
        --cache-control "$cache" \
        --only-show-errors
}

shopt -s nullglob
ZIPS=("$OUTDIR"/*.zip)
METAS=("$OUTDIR"/*-stable "$OUTDIR"/*-beta "$OUTDIR"/*-alpha)
[[ ${#ZIPS[@]} -gt 0 || ${#METAS[@]} -gt 0 ]] || { echo "no artifacts in $OUTDIR" >&2; exit 1; }

echo ">> R2 endpoint: $ENDPOINT   bucket: $BUCKET"

# 1) Immutable payloads first. Named per-build, so they can be cached forever.
for z in "${ZIPS[@]}"; do
    put "$z" "$(basename "$z")" "application/zip" "public, max-age=31536000, immutable"
done

# 2) Mutable channel pointer(s) last, uncacheable so a new build is seen promptly.
for m in "${METAS[@]}"; do
    put "$m" "$(basename "$m")" "text/plain; charset=utf-8" "no-store, must-revalidate"
done

echo ">> done. Served at https://ota.ma.vayunmathur.com/<file>"
