#!/usr/bin/env bash
#
# prepare-factory.sh — turn a MAOS factory image into what the web installer consumes:
# a manifest.json flash plan plus per-partition images (splitting any image larger than
# the device's max-download-size into sparse chunks), uploaded to R2.
#
# The web installer (ma.vayunmathur.com/os/install) fetches
#   https://ota.ma.vayunmathur.com/factory/<device>/latest/manifest.json
# and flashes each step, streaming the referenced images from the same directory.
#
# ── IMPORTANT ──────────────────────────────────────────────────────────────────────────
# The exact flash sequence (which partitions, slots, and order) is device/release specific
# and is authoritatively defined by the factory image's own flash-all.sh. The auto-generated
# plan here is a BEST-EFFORT scaffold. For a real release, pass an explicit plan with -P
# (a JSON array of steps) that mirrors that device's flash-all, and validate on a device
# before publishing. See installer/README.md.
# ─────────────────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   installer/prepare-factory.sh -d shusky -b 2026080900 -f <factory-image.zip> \
#       [-P plan.json] [-m 104857600] [-O out/maos-factory] [-B maos-ota] [--no-upload]
#
# R2 upload reuses the same env as ota/publish-ota.sh:
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_ACCOUNT_ID (or R2_ENDPOINT).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="" ; BUILD="" ; FACTORY="" ; PLAN="" ; MAXB=$((100 * 1024 * 1024))
OUTDIR="out/maos-factory" ; BUCKET="${R2_BUCKET:-maos}" ; UPLOAD=1

usage() { sed -n '2,30p' "$0" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) DEVICE="$2"; shift 2 ;;
        -b) BUILD="$2"; shift 2 ;;
        -f) FACTORY="$2"; shift 2 ;;
        -P) PLAN="$2"; shift 2 ;;
        -m) MAXB="$2"; shift 2 ;;
        -O) OUTDIR="$2"; shift 2 ;;
        -B) BUCKET="$2"; shift 2 ;;
        --no-upload) UPLOAD=0; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[[ -n "$DEVICE" && -n "$BUILD" && -n "$FACTORY" ]] || usage
[[ -f "$FACTORY" ]] || { echo "factory image not found: $FACTORY" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required (for sparse_split.py)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$OUTDIR/$DEVICE/$BUILD"
mkdir -p "$STAGE"

echo ">> unpacking factory image"
unzip -q -o "$FACTORY" -d "$WORK"
# Pixel factory images nest the partition images inside image-<device>-<build>.zip.
INNER="$(find "$WORK" -name 'image-*.zip' | head -1 || true)"
if [[ -n "$INNER" ]]; then
    unzip -q -o "$INNER" -d "$WORK/inner"
fi

# Collect a partition -> image-file map. Each *.img's partition is its basename sans .img.
declare -A IMG
add_img() { # add_img <path>
    local p; p="$(basename "$1")"; p="${p%.img}"
    # Normalize bootloader-/radio-<...> to bare partition names.
    case "$p" in
        bootloader-*) p="bootloader" ;;
        radio-*) p="radio" ;;
    esac
    IMG["$p"]="$1"
}
for f in "$WORK"/*.img "$WORK"/inner/*.img; do [[ -e "$f" ]] && add_img "$f"; done

# Stage an image for a partition, splitting into sparse chunks if it exceeds MAXB.
# Emits one or more manifest flash-step JSON objects on stdout.
stage_flash() { # stage_flash <partition> <src-image>
    local part="$1" src="$2" sz base steps=""
    sz="$(stat -c '%s' "$src")"
    base="$(basename "$src")"
    if (( sz <= MAXB )); then
        cp "$src" "$STAGE/$base"
        printf '{"action":"flash","partition":"%s","image":"%s"}' "$part" "$base"
    else
        echo "   splitting $base ($sz bytes) into sparse chunks <= $MAXB" >&2
        local prefix="$STAGE/${part}"
        # sparse_split prints each output path (one per line).
        local first=1
        while IFS= read -r chunk; do
            [[ $first -eq 1 ]] || steps+=","
            first=0
            steps+=$(printf '{"action":"flash","partition":"%s","image":"%s"}' \
                "$part" "$(basename "$chunk")")
        done < <(python3 "$HERE/sparse_split.py" "$src" "$prefix" --max-bytes "$MAXB")
        printf '%s' "$steps"
    fi
}

echo ">> building flash plan"
STEPS_JSON=""
append() { [[ -z "$STEPS_JSON" ]] || STEPS_JSON+=","; STEPS_JSON+="$1"; }

if [[ -n "$PLAN" ]]; then
    # Explicit plan: array of steps. `flash` steps name a partition + an image key that
    # must exist in IMG (or a literal file under the factory dir). We still split big ones.
    [[ -f "$PLAN" ]] || { echo "plan not found: $PLAN" >&2; exit 1; }
    command -v jq >/dev/null || { echo "jq required to use -P plan.json" >&2; exit 1; }
    while IFS= read -r line; do
        action="$(jq -r '.action' <<<"$line")"
        case "$action" in
            flash)
                part="$(jq -r '.partition' <<<"$line")"
                key="$(jq -r '.image' <<<"$line")"
                src="${IMG[$key]:-$WORK/$key}"
                [[ -e "$src" ]] || src="$WORK/inner/$key"
                [[ -e "$src" ]] || { echo "plan references missing image: $key" >&2; exit 1; }
                append "$(stage_flash "$part" "$src")"
                ;;
            *) append "$line" ;;
        esac
    done < <(jq -c '.[]' "$PLAN")
else
    echo "   WARNING: no -P plan.json given; generating a best-effort plan. VERIFY against" >&2
    echo "            the device's real flash-all before trusting this for a release." >&2
    [[ -n "${IMG[bootloader]:-}" ]] && { append "$(stage_flash bootloader "${IMG[bootloader]}")"; append '{"action":"reboot-bootloader"}'; }
    [[ -n "${IMG[radio]:-}" ]] && { append "$(stage_flash radio "${IMG[radio]}")"; append '{"action":"reboot-bootloader"}'; }
    for part in "${!IMG[@]}"; do
        case "$part" in bootloader|radio) continue ;; esac
        append "$(stage_flash "$part" "${IMG[$part]}")"
    done
    append '{"action":"erase","partition":"userdata"}'
    append '{"action":"reboot"}'
fi

MANIFEST="$STAGE/manifest.json"
cat > "$MANIFEST" <<EOF
{
  "device": "$DEVICE",
  "build": "$BUILD",
  "steps": [ $STEPS_JSON ]
}
EOF
echo ">> manifest: $MANIFEST"
echo "   $(find "$STAGE" -type f | wc -l) file(s) staged in $STAGE"

if [[ "$UPLOAD" -eq 0 ]]; then
    echo ">> --no-upload set; skipping R2 upload"
    exit 0
fi

# ---- Upload to R2 (mirrors ota/publish-ota.sh) ----
command -v aws >/dev/null || { echo "aws CLI (v2) required to upload" >&2; exit 1; }
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"
ENDPOINT="${R2_ENDPOINT:-}"
if [[ -z "$ENDPOINT" ]]; then
    : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID or R2_ENDPOINT}"
    ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"
export AWS_RESPONSE_CHECKSUM_VALIDATION="when_required"
s3() { aws s3 --endpoint-url "$ENDPOINT" "$@"; }

# Images first (immutable), manifest last (uncacheable) so the installer never sees a
# manifest pointing at a not-yet-uploaded image. Upload to the versioned path, then mirror
# to /latest/ which the installer reads by default.
for dest in "factory/$DEVICE/$BUILD" "factory/$DEVICE/latest"; do
    echo ">> uploading images -> s3://$BUCKET/$dest/"
    for img in "$STAGE"/*.img "$STAGE"/*.simg; do
        [[ -e "$img" ]] || continue
        s3 cp "$img" "s3://$BUCKET/$dest/$(basename "$img")" \
            --content-type "application/octet-stream" \
            --cache-control "public, max-age=31536000, immutable" --only-show-errors
    done
    echo ">> uploading manifest -> s3://$BUCKET/$dest/manifest.json"
    s3 cp "$MANIFEST" "s3://$BUCKET/$dest/manifest.json" \
        --content-type "application/json" \
        --cache-control "no-store, must-revalidate" --only-show-errors
done

echo ">> done. Installer will read https://ota.ma.vayunmathur.com/factory/$DEVICE/latest/manifest.json"
