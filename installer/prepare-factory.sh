#!/usr/bin/env bash
#
# prepare-factory.sh — turn a MAOS release image into what the web installer consumes:
# a manifest.json flash plan plus per-partition images, uploaded to R2.
#
# The web installer (ma.vayunmathur.com/os/install) fetches
#   https://ota.ma.vayunmathur.com/factory/<device>/latest/manifest.json
# and flashes each step, streaming the referenced images from the same directory.
#
# ── Two input modes ────────────────────────────────────────────────────────────────────
# 1. INSTALL ZIP (preferred, correct):  <device>-install-<build>.zip
#    Ships GrapheneOS's *verified* `script.txt` flash sequence plus the whole `super`
#    already pre-split into `super_*.img` (sized to the device max-download-size, flashed in
#    bootloader mode — the lowest-brick-risk path). When a `script.txt` is present we
#    translate it verbatim (installer/script_to_manifest.py) into ordered manifest steps and
#    copy the images AS-IS (no re-splitting). This is what phase_publish in build-maos.sh
#    passes and what a real release should use.
#
# 2. FACTORY ZIP (legacy fallback):     <device>-factory-<build>.zip  (or any -P plan.json)
#    No script.txt. We build a partition->image map and either follow an explicit -P plan or
#    emit a BEST-EFFORT scaffold (prints a warning). Oversized images are split into sparse
#    chunks with sparse_split.py. Treat the auto plan as a scaffold, not a guarantee, and
#    validate on a device before publishing. See installer/README.md.
# ─────────────────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   installer/prepare-factory.sh -d cheetah -b 2026081000 -f <device>-install-<build>.zip \
#       [-P plan.json] [-m 104857600] [-O out/maos-factory] [-B maos] [--no-upload]
#
# R2 upload reuses the same env as ota/publish-ota.sh:
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_ACCOUNT_ID (or R2_ENDPOINT).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="" ; BUILD="" ; FACTORY="" ; PLAN="" ; MAXB=$((100 * 1024 * 1024))
OUTDIR="out/maos-factory" ; BUCKET="${R2_BUCKET:-maos}" ; UPLOAD=1

usage() { sed -n '2,36p' "$0" >&2; exit 2; }

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
[[ -f "$FACTORY" ]] || { echo "image zip not found: $FACTORY" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$OUTDIR/$DEVICE/$BUILD"
mkdir -p "$STAGE"
MANIFEST="$STAGE/manifest.json"

echo ">> unpacking $FACTORY"
unzip -q -o "$FACTORY" -d "$WORK"

# Install-zip layout ships script.txt (GrapheneOS's verified flash sequence). Unless the
# caller forces an explicit -P plan, prefer translating that script verbatim.
SCRIPT_TXT="$(find "$WORK" -name script.txt | head -1 || true)"

if [[ -z "$PLAN" && -n "$SCRIPT_TXT" ]]; then
    # ---- Install-zip mode: translate script.txt, copy images as-is (no re-split) ----
    echo ">> install-zip detected (script.txt) — translating GrapheneOS flash sequence"
    SRCDIR="$(dirname "$SCRIPT_TXT")"
    python3 "$HERE/script_to_manifest.py" \
        --script "$SCRIPT_TXT" --device "$DEVICE" --build "$BUILD" --srcdir "$SRCDIR" \
        > "$MANIFEST" || { echo "script.txt translation failed" >&2; exit 1; }

    echo ">> copying referenced images as-is (super_*.img are already sized; no re-split)"
    # Every image the manifest's flash steps reference, from wherever it sits in the zip.
    while IFS= read -r img; do
        [[ -n "$img" ]] || continue
        src="$(find "$WORK" -name "$img" | head -1 || true)"
        [[ -n "$src" ]] || { echo "manifest references missing image: $img" >&2; exit 1; }
        cp "$src" "$STAGE/$img"
    done < <(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
for s in m["steps"]:
    if s.get("action") == "flash":
        print(s["image"])' "$MANIFEST")
else
    # ---- Legacy factory-zip mode: partition map + (explicit or best-effort) plan ----
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
        echo "   WARNING: no script.txt and no -P plan.json; generating a best-effort plan." >&2
        echo "            VERIFY against the device's real flash-all before trusting this." >&2
        [[ -n "${IMG[bootloader]:-}" ]] && { append "$(stage_flash bootloader "${IMG[bootloader]}")"; append '{"action":"reboot-bootloader"}'; }
        [[ -n "${IMG[radio]:-}" ]] && { append "$(stage_flash radio "${IMG[radio]}")"; append '{"action":"reboot-bootloader"}'; }
        for part in "${!IMG[@]}"; do
            case "$part" in bootloader|radio) continue ;; esac
            append "$(stage_flash "$part" "${IMG[$part]}")"
        done
        append '{"action":"erase","partition":"userdata"}'
        append '{"action":"reboot"}'
    fi

    cat > "$MANIFEST" <<EOF
{
  "device": "$DEVICE",
  "build": "$BUILD",
  "steps": [ $STEPS_JSON ]
}
EOF
fi

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
# to /latest/ which the installer reads by default. Everything except manifest.json is an
# image (.img/.simg/.bin) and is content-addressed + immutable.
for dest in "factory/$DEVICE/$BUILD" "factory/$DEVICE/latest"; do
    echo ">> uploading images -> s3://$BUCKET/$dest/"
    for img in "$STAGE"/*; do
        [[ -e "$img" ]] || continue
        [[ "$(basename "$img")" == "manifest.json" ]] && continue
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
