#!/usr/bin/env bash
#
# generate-keys.sh — create the MAOS signing key set on the (offline) build host.
#
# These are the OS keys, entirely separate from the app signing keys: the 9 Modern
# Apps ship `presigned` and keep their own com.vayunmathur certificate, so app updates
# via the app store keep working. Do NOT reuse an app key here, and do NOT reuse these
# for apps (a platform-signed app would be massively over-privileged).
#
# >>> The generated files are PRIVATE KEYS. Keep them OFFLINE, back them up, and NEVER
# >>> commit them. This repo's .gitignore excludes keys/*, but be careful anyway.
#
# Usage:
#   source build/envsetup.sh            # sets ANDROID_BUILD_TOP, adds avbtool to PATH
#   vendor/modern-apps/keys/generate-keys.sh ~/.android-certs ["/C=US/ST=.../CN=MAOS/..."]
#
set -euo pipefail

OUT="${1:?usage: generate-keys.sh <output-dir> [x509-subject]}"
SUBJECT="${2:-/C=US/ST=California/L=Burlingame/O=MAOS/OU=MAOS/CN=MAOS/emailAddress=security@vayunmathur.com}"

: "${ANDROID_BUILD_TOP:?run 'source build/envsetup.sh' in the AOSP tree first}"
MAKE_KEY="$ANDROID_BUILD_TOP/development/tools/make_key"
[[ -x "$MAKE_KEY" ]] || { echo "make_key not found at $MAKE_KEY" >&2; exit 1; }
command -v avbtool >/dev/null || { echo "avbtool not on PATH (source envsetup.sh / lunch)" >&2; exit 1; }

mkdir -p "$OUT"
cd "$OUT"

# The AOSP APK-signing key set. releasekey also signs the OTA payloads.
# platform/shared/media are classic; networkstack (A10+), sdk_sandbox (A14+) and
# bluetooth (A13+) are required by newer platforms — generating extras is harmless.
KEYS=(releasekey platform shared media networkstack sdk_sandbox bluetooth)

for k in "${KEYS[@]}"; do
    if [[ -f "$k.pk8" ]]; then
        echo "skip $k (already exists)"
        continue
    fi
    echo "generating $k ..."
    # Empty passphrase (piped) => unencrypted keys suitable for automated signing.
    # For encrypted keys, run make_key interactively and keep the passphrases in a
    # secrets manager the release job can read.
    echo | "$MAKE_KEY" "$k" "$SUBJECT"
done

# Verified Boot (AVB) key: RSA-4096 private key + its public-key metadata blob that
# gets embedded in vbmeta. Wired into the build via BOARD_AVB_* / the signing step
# (see docs/BUILD_RUNBOOK.md).
if [[ ! -f avb.pem ]]; then
    echo "generating avb.pem (RSA-4096) ..."
    openssl genrsa -out avb.pem 4096
    avbtool extract_public_key --key avb.pem --output avb_pkmd.bin
else
    echo "skip avb.pem (already exists)"
fi

chmod 600 ./*.pk8 ./*.pem 2>/dev/null || true

cat <<EOF

Done. Key set written to: $OUT
  APK/OTA keys : ${KEYS[*]} (.pk8 + .x509.pem each)
  AVB          : avb.pem (private) + avb_pkmd.bin (public metadata)

Next:
  * Keep this directory OFFLINE and backed up. Losing releasekey/avb bricks OTA updates
    for every installed device (they can only accept updates signed by the same keys).
  * Never commit these files.
  * See docs/BUILD_RUNBOOK.md for wiring them into the build + signing + OTA steps.
EOF
