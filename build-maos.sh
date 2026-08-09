#!/usr/bin/env bash
#
# build-maos.sh — one-shot(ish) MAOS builder for Pixel 7 Pro (cheetah) on a GrapheneOS tag.
#
# Runs everything in docs/BUILD_RUNBOOK.md EXCEPT the Windows/WSL2 setup: install deps, sync
# the source, extract vendor files, wire in the MAOS overlay, (generate &) use signing keys,
# build, produce a signed release, and publish OTA + web-installer artifacts to R2.
#
# It is phase-based and resumable — rerun a phase or the whole thing safely.
#
#   ./build-maos.sh all                         # full pipeline
#   ./build-maos.sh sync                         # just one phase
#   ./build-maos.sh -d panther -t 2026080500 all # override device/tag via flags
#
# Usage: ./build-maos.sh [-d DEVICE] [-t TAG] [-c CHANNEL] <phase...>
#   -d DEVICE    Pixel codename / build target   (default: cheetah)
#   -t TAG       GrapheneOS base tag             (default: 2026080500)
#   -c CHANNEL   OTA channel to publish          (default: stable; stable|beta|testing)
#   phases: deps sync vendor overlay keys build release publish all
#
# ── Signing keys ────────────────────────────────────────────────────────────────────────
# Keys live in ONE scrypt-encrypted file ($MAOS_KEYS_FILE), unlocked with a passphrase you
# pass in the environment ($MAOS_KEYS_PASSPHRASE). On first run (file absent) the `keys` phase
# generates the full key set and encrypts it into that file. On every build/release the
# script decrypts it into RAM (/dev/shm), uses it, and shreds the plaintext on exit — the
# keys are never written to disk in the clear.
#
# ── Required environment ────────────────────────────────────────────────────────────────
#   MAOS_KEYS_PASSPHRASE   passphrase for the encrypted key file (required for keys/build/release)
# For publishing:
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY   Cloudflare R2 creds
#
# ── Optional environment ────────────────────────────────────────────────────────────────
#   MAOS_KEYS_FILE=$HOME/maos-keys/$DEVICE.keys.tar.gz.enc   encrypted key blob (outside the tree)
#   MODERN_APPS_SRC=<path>         Modern-Apps checkout/dir with release APKs; if unset, the 9
#                                  APKs are downloaded from the Modern-Apps GitHub release
#
# ── Hardcoded ─────────────────────────────────────────────────────────────────────────────
#   TREE=$HOME/maos (ext4 checkout)   R2_BUCKET=maos   BUILD=<tag> (matches the GrapheneOS tag)
#
set -euo pipefail

# ---- Parameters (flags) ----
DEVICE="cheetah"
TAG="2026080500"
OTA_CHANNEL="stable"
while getopts "d:t:c:h" _opt; do
    case "$_opt" in
        d) DEVICE="$OPTARG" ;;
        t) TAG="$OPTARG" ;;
        c) OTA_CHANNEL="$OPTARG" ;;
        h) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "usage: $0 [-d DEVICE] [-t TAG] [-c CHANNEL] <phase...>" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# ---- Hardcoded config ----
TREE="$HOME/maos"                              # AOSP checkout (ext4; never /mnt/c)
R2_BUCKET="maos"                               # R2 bucket / ota.ma.vayunmathur.com
# The release build number always matches the GrapheneOS base tag (their tags are the build
# numbers), so OTA/version identity lines up with the upstream release.
BUILD="$TAG"
MANIFEST_URL="https://github.com/GrapheneOS/platform_manifest.git"
MAOS_GH="https://github.com/vayun-mathur/"     # overlay repo remote (for the local manifest)
MODERN_APPS_GH="vayun-mathur/Modern-Apps"      # source of the prebuilt APKs
APPS=(web camera pdf contacts calculator clock files photos appstore keyboard speech calendar music)

# ---- Derived / optional-env config ----
MAOS_KEYS_FILE="${MAOS_KEYS_FILE:-$HOME/maos-keys/$DEVICE.keys.tar.gz.scrypt}"
MODERN_APPS_SRC="${MODERN_APPS_SRC:-}"

# Plaintext keys are only ever materialized here (RAM-backed), and shredded on exit.
KEYS_PLAIN="/dev/shm/maos-keys-$DEVICE"

# Prefer user-writable tool installs (a writable `repo` launcher so it can self-update instead
# of warning, plus anything else we drop in ~/.local/bin) over system copies.
export PATH="$HOME/.local/bin:$PATH"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- Key handling (scrypt-encrypted blob <-> RAM) ----

# Plaintext tarball lives only in RAM (/dev/shm) alongside KEYS_PLAIN, and is shredded.
KEYS_TAR="$KEYS_PLAIN.tar.gz"

wipe_plain_keys() {
    for f in "$KEYS_TAR"; do [[ -f "$f" ]] && shred -u "$f" 2>/dev/null || true; done
    if [[ -d "$KEYS_PLAIN" ]]; then
        find "$KEYS_PLAIN" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "$KEYS_PLAIN"
    fi
    # Drop the in-tree symlink to the RAM keys, if we made one.
    [[ -L "$TREE/keys/$DEVICE" ]] && rm -f "$TREE/keys/$DEVICE" || true
}
trap wipe_plain_keys EXIT

# Keys are encrypted with scrypt (KDF) + AES-256 via the `scrypt` utility — more
# brute-force-resistant than PBKDF2 for an offline attacker with the blob. The passphrase is
# read from the environment, never the command line. `--passphrase env:` requires scrypt 1.3+.
scrypt_enc() { scrypt enc --passphrase env:MAOS_KEYS_PASSPHRASE "$1" "$2"; }
scrypt_dec() { scrypt dec --passphrase env:MAOS_KEYS_PASSPHRASE "$1" "$2"; }

require_passphrase() {
    [[ -n "${MAOS_KEYS_PASSPHRASE:-}" ]] || die "MAOS_KEYS_PASSPHRASE must be set."
    command -v scrypt >/dev/null || die "the 'scrypt' utility is missing — run the 'deps' phase."
}

# Decrypt the key blob into RAM and symlink it in as $TREE/keys/$DEVICE for the GrapheneOS
# signing scripts (which read keys from keys/<device>).
unlock_keys() {
    require_passphrase
    [[ -f "$MAOS_KEYS_FILE" ]] || die "Key file $MAOS_KEYS_FILE not found — run the 'keys' phase first."
    log "Unlocking signing keys into RAM"
    rm -rf "$KEYS_PLAIN"; mkdir -p "$KEYS_PLAIN"; chmod 700 "$KEYS_PLAIN"
    rm -f "$KEYS_TAR"
    scrypt_dec "$MAOS_KEYS_FILE" "$KEYS_TAR" || die "Failed to decrypt keys (wrong passphrase?)."
    tar xzf "$KEYS_TAR" -C "$KEYS_PLAIN"
    shred -u "$KEYS_TAR" 2>/dev/null || rm -f "$KEYS_TAR"
    mkdir -p "$TREE/keys"
    rm -rf "$TREE/keys/$DEVICE"
    ln -s "$KEYS_PLAIN" "$TREE/keys/$DEVICE"
}

# ---- Phases ----

phase_deps() {
    log "Installing build dependencies"
    # ISP has no IPv6: force apt over IPv4 so it doesn't stall on unreachable IPv6 mirrors.
    echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null
    sudo apt update
    sudo apt install -y \
        yarnpkg zip unzip rsync git gnupg openssh-client scrypt \
        python3 python-is-python3 diffutils hostname openssl \
        libfreetype6 fontconfig fonts-dejavu-core \
        build-essential curl
    # `repo`: install the official launcher to a WRITABLE location (~/.local/bin) rather than
    # apt's /usr/bin/repo, which is read-only and makes repo warn it "can't self-update".
    mkdir -p "$HOME/.local/bin"
    if [[ ! -x "$HOME/.local/bin/repo" ]]; then
        curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.local/bin/repo"
        chmod a+x "$HOME/.local/bin/repo"
    fi
    grep -q '.local/bin' ~/.bashrc 2>/dev/null || \
        echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
    # AWS CLI v2 (used for R2 uploads). The `awscli` apt package was removed in newer
    # Ubuntu, so install the official v2 bundle if `aws` isn't already present.
    if ! command -v aws >/dev/null; then
        log "Installing AWS CLI v2 from the official bundle"
        local t; t="$(mktemp -d)"
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$t/awscliv2.zip"
        unzip -q "$t/awscliv2.zip" -d "$t"
        sudo "$t/aws/install" --update
        rm -rf "$t"
    fi
    grep -q '/usr/local/sbin' ~/.bashrc 2>/dev/null || \
        echo 'export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin' >> ~/.bashrc
    export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
    if ! command -v node >/dev/null || [[ "$(node -v 2>/dev/null | cut -c2-3)" -lt 24 ]]; then
        log "Installing Node.js 24 + yarn (for adevtool)"
        [[ -s "$HOME/.nvm/nvm.sh" ]] || \
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        . "$HOME/.nvm/nvm.sh"
        nvm install 24
        npm install -g yarn
    fi
}

phase_sync() {
    log "Syncing GrapheneOS $TAG into $TREE"
    case "$TREE" in /mnt/*) die "TREE is under /mnt (Windows FS). Use ext4, e.g. \$HOME/maos.";; esac
    # repo requires a git identity for its internal manifest project.
    git config --global user.name  >/dev/null 2>&1 || git config --global user.name "Vayun Mathur"
    git config --global user.email >/dev/null 2>&1 || \
        git config --global user.email "69178052+vayun-mathur@users.noreply.github.com"
    # Pre-set color so `repo init` doesn't stop for the interactive color prompt.
    git config --global color.ui >/dev/null 2>&1 || git config --global color.ui auto
    mkdir -p "$TREE"; cd "$TREE"
    repo init -u "$MANIFEST_URL" -b "refs/tags/$TAG"

    # Verify the manifest signature.
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    curl -fsS https://grapheneos.org/allowed_signers > ~/.ssh/grapheneos_allowed_signers
    ( cd .repo/manifests
      git config gpg.ssh.allowedSignersFile ~/.ssh/grapheneos_allowed_signers
      git verify-tag "$(git describe)" ) || die "Manifest tag verification failed."

    # Inject the MAOS overlay via a local manifest (no fork of platform_manifest).
    mkdir -p .repo/local_manifests
    cat > .repo/local_manifests/modern-apps.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="maos-github" fetch="$MAOS_GH" />
  <project path="vendor/modern-apps" name="MAOS" remote="maos-github" revision="main" />
</manifest>
EOF
    log "repo sync (this downloads ~150 GB; resumable)"
    repo sync -j8
}

phase_vendor() {
    log "Extracting Pixel vendor files for $DEVICE (adevtool)"
    cd "$TREE"; source build/envsetup.sh
    yarn --cwd vendor/adevtool/ install
    # adevtool is an oclif CLI — its launcher is vendor/adevtool/bin/run (there is no global
    # `adevtool` command, and `yarn run adevtool` has no such script). Prefer bin/run, with
    # fallbacks for older layouts / a PATH install.
    local ADEV
    if   [[ -x vendor/adevtool/bin/run ]];      then ADEV=(vendor/adevtool/bin/run)
    elif [[ -x vendor/adevtool/bin/adevtool ]]; then ADEV=(vendor/adevtool/bin/adevtool)
    elif command -v adevtool >/dev/null;        then ADEV=(adevtool)
    else die "adevtool launcher not found under vendor/adevtool/bin (did 'yarn install' succeed?)"
    fi
    "${ADEV[@]}" generate-all -d "$DEVICE"
}

phase_overlay() {
    cd "$TREE"

    log "Populating Modern Apps prebuilt APKs"
    local dest="vendor/modern-apps/prebuilts"; mkdir -p "$dest"
    if [[ -n "$MODERN_APPS_SRC" ]]; then
        vendor/modern-apps/scripts/collect-apks.sh "$MODERN_APPS_SRC"
    else
        warn "MODERN_APPS_SRC unset — downloading APKs from the $MODERN_APPS_GH latest release."
        for app in "${APPS[@]}"; do
            curl -fL -o "$dest/$app-release.apk" \
                "https://github.com/$MODERN_APPS_GH/releases/latest/download/$app-release.apk" \
                || die "Could not download $app-release.apk"
        done
    fi

    log "Verifying stock module names against this tag"
    grep -rn --include=*.mk -e '\bCamera\b' -e '\bPdfViewer\b' -e '\bApps\b' \
        -e '\bContacts\b' -e '\bDeskClock\b' -e 'Calculator' -e 'Gallery2' -e 'DocumentsUI' \
        build/ device/ vendor/ | grep -i 'PRODUCT_PACKAGES' || true
    warn "Confirm the names above match the filter-out list in vendor/modern-apps/modern_apps.mk."

    log "Wiring MAOS product config into the $DEVICE makefile"
    local mk
    mk="$(find device/google -name "aosp_${DEVICE}.mk" | head -1)"
    [[ -n "$mk" ]] || mk="$(find device/google -name "*${DEVICE}*.mk" | head -1)"
    [[ -n "$mk" ]] || die "Could not find the product makefile for $DEVICE."
    if ! grep -q 'vendor/modern-apps/modern_apps.mk' "$mk"; then
        printf '\n$(call inherit-product, vendor/modern-apps/modern_apps.mk)\n' >> "$mk"
        log "Appended MAOS inherit to $mk"
    else
        log "MAOS inherit already present in $mk"
    fi

    log "Pointing the Updater at ota.ma.vayunmathur.com"
    local cfg="packages/apps/Updater/res/values/config.xml"
    [[ -f "$cfg" ]] && sed -i 's#https://releases.grapheneos.org#https://ota.ma.vayunmathur.com#g' "$cfg" \
        || warn "Updater config.xml not found; set the URL manually if OFFICIAL_BUILD is used."
}

phase_keys() {
    require_passphrase
    if [[ -f "$MAOS_KEYS_FILE" ]]; then
        log "Key file already exists ($MAOS_KEYS_FILE) — skipping generation."
        return 0
    fi
    log "Generating signing keys (into RAM, then encrypting to $MAOS_KEYS_FILE)"
    cd "$TREE"; source build/envsetup.sh
    rm -rf "$KEYS_PLAIN"; mkdir -p "$KEYS_PLAIN"; chmod 700 "$KEYS_PLAIN"
    local CN="MAOS"
    for k in releasekey platform shared media networkstack bluetooth sdk_sandbox gmscompat_lib nfc; do
        echo | development/tools/make_key "$KEYS_PLAIN/$k" "/CN=$CN/" || die "make_key $k failed"
    done
    openssl genrsa 4096 | openssl pkcs8 -topk8 -scrypt -out "$KEYS_PLAIN/avb.pem" -passout pass:
    external/avb/avbtool.py extract_public_key --key "$KEYS_PLAIN/avb.pem" \
        --output "$KEYS_PLAIN/avb_pkmd.bin"
    ssh-keygen -t ed25519 -N "" -f "$KEYS_PLAIN/id_ed25519" >/dev/null

    mkdir -p "$(dirname "$MAOS_KEYS_FILE")"
    rm -f "$KEYS_TAR"
    tar czf "$KEYS_TAR" -C "$KEYS_PLAIN" .
    scrypt_enc "$KEYS_TAR" "$MAOS_KEYS_FILE"
    shred -u "$KEYS_TAR" 2>/dev/null || rm -f "$KEYS_TAR"
    chmod 600 "$MAOS_KEYS_FILE"
    log "Encrypted key set (scrypt) written to $MAOS_KEYS_FILE — back it up; losing it bricks OTA."
}

phase_build() {
    log "Building MAOS for $DEVICE (tag $TAG, build $BUILD)"
    cd "$TREE"; source build/envsetup.sh
    export OFFICIAL_BUILD=true
    lunch "${DEVICE}-cur-user"
    rm -rf out
    # Pixel 7 Pro needs the vendor boot + vendor kernel boot images.
    m vendorbootimage vendorkernelbootimage target-files-package
}

phase_release() {
    log "Signing + generating factory image and full OTA"
    cd "$TREE"; source build/envsetup.sh
    unlock_keys
    m otatools-package
    script/finalize.sh
    script/generate-release.sh "$DEVICE" "$BUILD"
    log "Release at releases/$BUILD/release-$DEVICE-$BUILD"
}

phase_publish() {
    : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"; : "${R2_ACCESS_KEY_ID:?}"; : "${R2_SECRET_ACCESS_KEY:?}"
    cd "$TREE"
    local rel="releases/$BUILD/release-$DEVICE-$BUILD"
    [[ -d "$rel" ]] || die "Release dir $rel not found — run the 'release' phase first."

    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION=auto
    export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
    export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
    local EP="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
    r2() { aws s3 --endpoint-url "$EP" "$@"; }

    log "Publishing OTA (zip first, channel metadata last)"
    r2 cp "$rel/$DEVICE-ota_update-$BUILD.zip" "s3://$R2_BUCKET/" \
        --content-type application/zip --cache-control 'public, max-age=31536000, immutable' \
        --only-show-errors
    r2 cp "$rel/$DEVICE-$OTA_CHANNEL" "s3://$R2_BUCKET/" \
        --content-type 'text/plain; charset=utf-8' --cache-control 'no-store, must-revalidate' \
        --only-show-errors

    log "Publishing factory image for the web installer"
    R2_BUCKET="$R2_BUCKET" vendor/modern-apps/installer/prepare-factory.sh \
        -d "$DEVICE" -b "$BUILD" -f "$rel/$DEVICE-factory-$BUILD.zip" \
        || warn "prepare-factory.sh failed — see its output. For a real release pass -P plan.json \
mirroring flash-all (incl. flashing avb_custom_key before lock)."
    log "Done. OTA: https://ota.ma.vayunmathur.com/$DEVICE-$OTA_CHANNEL"
}

# ---- Dispatch ----
run_phase() {
    case "$1" in
        deps) phase_deps ;;
        sync) phase_sync ;;
        vendor) phase_vendor ;;
        overlay) phase_overlay ;;
        keys) phase_keys ;;
        build) phase_build ;;
        release) phase_release ;;
        publish) phase_publish ;;
        all)
            phase_deps; phase_sync; phase_vendor; phase_overlay
            phase_keys; phase_build; phase_release; phase_publish ;;
        *) die "Unknown phase '$1'. Use: deps sync vendor overlay keys build release publish all" ;;
    esac
}

[[ $# -gt 0 ]] || { echo "usage: $0 [-d DEVICE] [-t TAG] [-c CHANNEL] <phase...>   (phases: deps sync vendor overlay keys build release publish all)"; exit 2; }
log "MAOS build — device=$DEVICE tag=$TAG build=$BUILD channel=$OTA_CHANNEL tree=$TREE bucket=$R2_BUCKET"
for p in "$@"; do run_phase "$p"; done
log "All requested phases complete."
