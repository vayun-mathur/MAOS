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
#   ./build-maos.sh all                         # full pipeline (cheetah)
#   ./build-maos.sh sync                         # just one phase
#   ./build-maos.sh -d panther -t 2026080500 all # override device/tag via flags
#   ./build-maos.sh -d all all                   # build EVERY supported Pixel
#   ./build-maos.sh -d cheetah,panther build     # a comma-separated subset
#
# Usage: ./build-maos.sh [-d DEVICE] [-t TAG] [-c CHANNEL] <phase...>
#   -d DEVICE    Pixel codename / build target   (default: cheetah)
#                 - a single codename (e.g. cheetah)
#                 - "all" to build every supported Pixel (see ALL_DEVICES)
#                 - a comma-separated subset (e.g. cheetah,panther)
#   -t TAG       GrapheneOS base tag             (default: 2026080500)
#   -c CHANNEL   OTA channel to publish          (default: stable; stable|beta|testing)
#   phases: deps sync vendor overlay keys build release publish all
#
# deps/sync/keys are device-independent and run ONCE; vendor/overlay/build run per device
# (sequential — each build saturates the machine), then release runs across devices IN
# PARALLEL (up to $MAOS_RELEASE_JOBS at once; it's decoupled from out/), then publish runs
# per device. A failed device is logged and skipped for its later phases; the run continues
# and a pass/fail summary is printed at the end.
#
# ── Signing keys ────────────────────────────────────────────────────────────────────────
# Keys live in ONE scrypt-encrypted file ($MAOS_KEYS_FILE), unlocked with a passphrase you
# pass in the environment ($MAOS_KEYS_PASSPHRASE). On first run (file absent) the `keys` phase
# generates the full key set and encrypts it into that file. On every build/release the
# script decrypts it into RAM (/dev/shm), uses it, and shreds the plaintext on exit — the
# keys are never written to disk in the clear.
#
# The key set is DEVICE-INDEPENDENT: one shared set signs every device (the GrapheneOS
# signing scripts read keys from keys/<device>, so the release phase decrypts the set once
# into RAM and symlinks it in as keys/<device> for whichever device is being built).
#
# ── Required environment ────────────────────────────────────────────────────────────────
#   MAOS_KEYS_PASSPHRASE   passphrase for the encrypted key file (required for keys/build/release)
# For publishing:
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY   Cloudflare R2 creds
#
# ── Optional environment ────────────────────────────────────────────────────────────────
#   MAOS_KEYS_FILE=$HOME/maos-keys/maos.keys.tar.gz.scrypt   encrypted key blob (shared, outside the tree)
#   MODERN_APPS_SRC=<path>         Modern-Apps checkout/dir with release APKs; if unset, the 9
#                                  APKs are downloaded from the Modern-Apps GitHub release
#   MAOS_RELEASE_JOBS=<n>          how many devices to sign/package (release) in parallel (default 4).
#                                  Lower it if a big multi-device release run runs low on RAM/disk.
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
        h) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "usage: $0 [-d DEVICE] [-t TAG] [-c CHANNEL] <phase...>" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# Every supported Pixel (fastboot codenames), kept in sync with the web installer's DEVICES
# map (location_share_server/os_installer/installer.js). `-d all` expands to this list.
ALL_DEVICES=(stallion rango mustang blazer frankel tegu comet komodo caiman tokay \
             akita husky shiba felix tangorpro lynx cheetah panther bluejay raven oriole)

# Expand -d into DEVICES_LIST: "all" -> every device; "a,b,c" -> that subset; else a single device.
if [[ "$DEVICE" == "all" ]]; then
    DEVICES_LIST=("${ALL_DEVICES[@]}")
elif [[ "$DEVICE" == *,* ]]; then
    IFS=',' read -r -a DEVICES_LIST <<< "$DEVICE"
else
    DEVICES_LIST=("$DEVICE")
fi

# ---- Hardcoded config ----
TREE="$HOME/maos"                              # AOSP checkout (ext4; never /mnt/c)
R2_BUCKET="maos"                               # R2 bucket / ota.ma.vayunmathur.com
# Default the build number to the tag, but phase_release/phase_publish override it with the
# ACTUAL number GrapheneOS generates at build time (out/soong/build_number.txt) via
# resolve_build_number -- that is what finalize.sh and the artifacts are named with. Tag and
# build number only coincide when you build on the tag's own date.
BUILD="$TAG"
MANIFEST_URL="https://github.com/GrapheneOS/platform_manifest.git"
MAOS_GH="https://github.com/vayun-mathur/"     # overlay repo remote (for the local manifest)
MODERN_APPS_GH="vayun-mathur/Modern-Apps"      # source of the prebuilt APKs
APPS=(web camera pdf contacts calculator clock files photos appstore keyboard speech calendar music networklocation)

# ---- Derived / optional-env config ----
# ONE shared, device-independent key set (see the "Signing keys" note above).
MAOS_KEYS_FILE="${MAOS_KEYS_FILE:-$HOME/maos-keys/maos.keys.tar.gz.scrypt}"
MODERN_APPS_SRC="${MODERN_APPS_SRC:-}"

# Plaintext keys are only ever materialized here (RAM-backed), and shredded on exit.
KEYS_PLAIN="/dev/shm/maos-keys"

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
    # Drop every in-tree symlink to the RAM keys we created (one keys/<device> per built device).
    if [[ -d "$TREE/keys" ]]; then
        for _l in "$TREE"/keys/*; do
            [[ -L "$_l" ]] && rm -f "$_l" || true
        done
    fi
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

# Decrypt the shared key blob into RAM once (idempotent). The GrapheneOS signing scripts read
# keys from keys/<device>, so link_keys symlinks this one RAM key set in per device. Splitting
# "unlock once" from "link per device" lets the release phase run in parallel across devices
# without racing on decryption.
unlock_keys_shared() {
    require_passphrase
    [[ -f "$MAOS_KEYS_FILE" ]] || die "Key file $MAOS_KEYS_FILE not found — run the 'keys' phase first."
    # Already unlocked this run? (releasekey.pk8 is always in the set.)
    [[ -s "$KEYS_PLAIN/releasekey.pk8" ]] && return 0
    log "Unlocking signing keys into RAM (shared across devices)"
    rm -rf "$KEYS_PLAIN"; mkdir -p "$KEYS_PLAIN"; chmod 700 "$KEYS_PLAIN"
    rm -f "$KEYS_TAR"
    scrypt_dec "$MAOS_KEYS_FILE" "$KEYS_TAR" || die "Failed to decrypt keys (wrong passphrase?)."
    tar xzf "$KEYS_TAR" -C "$KEYS_PLAIN"
    shred -u "$KEYS_TAR" 2>/dev/null || rm -f "$KEYS_TAR"
}

link_keys() { # link_keys <device> — symlink the shared RAM key set in as keys/<device>
    mkdir -p "$TREE/keys"
    rm -rf "$TREE/keys/$1"
    ln -s "$KEYS_PLAIN" "$TREE/keys/$1"
}

# Resolve $BUILD to the real build number GrapheneOS generated (date-based), written to
# out/soong/build_number.txt during the build. finalize.sh and the produced artifacts are named
# with THIS number, not the base tag, so release/publish must use it too.
resolve_build_number() {
    local f="$TREE/out/soong/build_number.txt"
    if [[ -f "$f" ]]; then
        BUILD="$(cat "$f")"
        log "Using build number $BUILD (from out/soong/build_number.txt)"
    else
        warn "out/soong/build_number.txt not found; using BUILD=$BUILD (tag) as a fallback."
    fi
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

populate_prebuilts() {
    cd "$TREE"
    local dest="vendor/modern-apps/prebuilts"; mkdir -p "$dest"
    # The Modern Apps APKs are device-independent, so only populate them once: skip if every
    # APK is already present and non-empty (this makes it a no-op on every device after the
    # first in a multi-device run instead of re-downloading all of them each time).
    local missing=0 app
    for app in "${APPS[@]}"; do [[ -s "$dest/$app-release.apk" ]] || { missing=1; break; }; done
    if [[ "$missing" -eq 0 ]]; then
        log "Modern Apps prebuilt APKs already present — skipping."
        return 0
    fi
    log "Populating Modern Apps prebuilt APKs"
    if [[ -n "$MODERN_APPS_SRC" ]]; then
        vendor/modern-apps/scripts/collect-apks.sh "$MODERN_APPS_SRC"
    else
        warn "MODERN_APPS_SRC unset - downloading APKs from the $MODERN_APPS_GH latest release."
        for app in "${APPS[@]}"; do
            curl -fL -o "$dest/$app-release.apk" \
                "https://github.com/$MODERN_APPS_GH/releases/latest/download/$app-release.apk" \
                || die "Could not download $app-release.apk"
        done
    fi
}

phase_vendor() {
    log "Extracting Pixel vendor files for $DEVICE (adevtool)"
    cd "$TREE"; source build/envsetup.sh
    # Modern Apps prebuilt APKs must exist before adevtool generate-all triggers a
    # soong build that parses vendor/modern-apps/Android.bp (globs prebuilts/*-release.apk).
    populate_prebuilts
    # adevtool's node deps are device-independent; install them once (skip if already present).
    [[ -d vendor/adevtool/node_modules ]] || yarn --cwd vendor/adevtool/ install
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

    # Modern Apps prebuilt APKs are populated in phase_vendor (populate_prebuilts),
    # before adevtool runs soong; nothing to do here.

    log "Verifying stock module names against this tag"
    grep -rn --include=*.mk -e '\bCamera\b' -e '\bPdfViewer\b' -e '\bApps\b' \
        -e '\bContacts\b' -e '\bDeskClock\b' -e 'Calculator' -e 'Gallery2' -e 'DocumentsUI' \
        build/ device/ vendor/ | grep -i 'PRODUCT_PACKAGES' || true
    warn "Confirm the names above match the filter-out list in vendor/modern-apps/modern_apps.mk."

    log "Wiring MAOS product config into the $DEVICE makefile"
    # GrapheneOS generates the device product makefile under vendor/google_devices/<dev>/
    # (there is no device/google/<family> product tree); prefer that, then fall back to
    # older device/google layouts.
    local mk="" _cand
    for _cand in \
        "vendor/google_devices/${DEVICE}/${DEVICE}.mk" \
        "$(find device/google -name "aosp_${DEVICE}.mk" 2>/dev/null | head -1)" \
        "$(find device/google -name "*${DEVICE}*.mk" 2>/dev/null | head -1)"; do
        if [[ -n "$_cand" && -f "$_cand" ]]; then mk="$_cand"; break; fi
    done
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
        # AOSP make_key always exits 1 via its EXIT trap even on success; ignore its exit
        # status and verify the generated artifacts instead.
        echo | development/tools/make_key "$KEYS_PLAIN/$k" "/CN=$CN/" || true
        [[ -s "$KEYS_PLAIN/$k.pk8" && -s "$KEYS_PLAIN/$k.x509.pem" ]] || die "make_key $k failed"
    done
    # AVB key must be an unencrypted RSA PEM: avbtool reads it non-interactively, and
    # an encrypted key makes load_public_key() fall through to ML-DSA (unsupported by
    # the system openssl). The whole key set is scrypt-encrypted later into MAOS_KEYS_FILE.
    openssl genrsa -out "$KEYS_PLAIN/avb.pem" 4096
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
    log "Building MAOS for $DEVICE (tag $TAG, build ${BUILD_NUMBER:-$BUILD})"
    cd "$TREE"; source build/envsetup.sh
    export OFFICIAL_BUILD=true
    lunch "${DEVICE}-cur-user"
    rm -rf out
    # Pixel 6 (Tensor G1: bluejay/raven/oriole) has no separate vendor_kernel_boot image;
    # every device since the Pixel 6a does. Building vendorkernelbootimage for a Pixel 6 fails.
    local boot_targets="vendorbootimage vendorkernelbootimage"
    case "$DEVICE" in bluejay|raven|oriole) boot_targets="vendorbootimage" ;; esac
    # Build device images, target-files AND otatools in one graph pass (as GrapheneOS does);
    # otatools is device-independent host tooling that finalize/generate-release need.
    m $boot_targets target-files-package otatools-package
    # Stage <device>-target_files.zip + <device>-otatools.zip into releases/<build>/ so the
    # release phase runs decoupled from out/ (hence in parallel across devices). finalize.sh
    # reads BUILD_NUMBER/OUT/ANDROID_HOST_OUT/TARGET_PRODUCT from the lunch'd env.
    resolve_build_number
    export BUILD_NUMBER="$BUILD"
    script/finalize.sh
    log "Staged target_files + otatools for $DEVICE into releases/$BUILD/"
}

phase_release() {
    # Decoupled from out/: generate-release.sh works entirely from the staged
    # releases/<build>/<device>-{target_files,otatools}.zip, so this can run in parallel across
    # devices. Keys are unlocked into RAM + symlinked as keys/<device> by the dispatch before
    # the release pass (so parallel jobs don't race on decryption); the fallback below covers a
    # standalone `release` invocation.
    log "Signing + generating factory image and full OTA for $DEVICE (build $BUILD)"
    cd "$TREE"
    if [[ ! -L "$TREE/keys/$DEVICE" ]]; then
        unlock_keys_shared
        link_keys "$DEVICE"
    fi
    # GrapheneOS's script/decrypt-keys (invoked by generate-release.sh) prompts for the
    # passphrase the per-key .pk8/avb.pem are encrypted with. build-maos.sh keeps the individual
    # keys UNENCRYPTED inside the scrypt blob (already unlocked into RAM), so that passphrase is
    # empty. Predefine it so decrypt-keys runs non-interactively and takes the plaintext path
    # instead of trying to decrypt an already-plaintext key (openssl "asn1 wrong tag" error).
    export password=""
    script/generate-release.sh "$DEVICE" "$BUILD"
    log "Release at releases/$BUILD/release-$DEVICE-$BUILD"
}

phase_publish() {
    : "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"; : "${R2_ACCESS_KEY_ID:?}"; : "${R2_SECRET_ACCESS_KEY:?}"
    cd "$TREE"
    resolve_build_number
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
    # The web installer consumes the *install* zip (contains super_1..N.img already split to
    # the device max-download-size, plus script.txt — GrapheneOS's verified flash sequence).
    # prepare-factory.sh translates that script.txt into the ordered installer manifest.
    R2_BUCKET="$R2_BUCKET" vendor/modern-apps/installer/prepare-factory.sh \
        -d "$DEVICE" -b "$BUILD" -f "$rel/$DEVICE-install-$BUILD.zip" \
        || warn "prepare-factory.sh failed — see its output. For a factory-zip fallback pass -P \
plan.json mirroring flash-all (incl. flashing avb_custom_key before lock)."
    log "Done. OTA: https://ota.ma.vayunmathur.com/$DEVICE-$OTA_CHANNEL"
}

# ---- Dispatch ----
# Run phase_release for each device argument, up to MAOS_RELEASE_JOBS (default 4) at a time.
# Release is decoupled from out/ (works from the staged target_files/otatools zips), so it
# parallelizes safely; builds themselves stay sequential (each saturates the machine). Each
# job runs in a subshell (set -e -> abort just that device; EXIT key-wipe trap reset inside
# subshells), and its output goes to a per-device log. Appends successes to RELEASED_OK.
run_release_parallel() {
    local jobs="${MAOS_RELEASE_JOBS:-4}"
    local logdir="$TREE/releases/$BUILD/logs"; mkdir -p "$logdir"
    log "Releasing $# device(s), up to $jobs at a time (MAOS_RELEASE_JOBS); logs in $logdir"
    local -a bpids=() bdevs=(); local dev i
    for dev in "$@"; do
        ( set -e; DEVICE="$dev"; phase_release ) >"$logdir/release-$dev.log" 2>&1 &
        bpids+=("$!"); bdevs+=("$dev")
        log "release[$dev] started (pid $!) -> $logdir/release-$dev.log"
        if (( ${#bpids[@]} >= jobs )); then
            for i in "${!bpids[@]}"; do
                if wait "${bpids[$i]}"; then log "release[${bdevs[$i]}] OK"; RELEASED_OK+=("${bdevs[$i]}")
                else warn "release[${bdevs[$i]}] FAILED — see $logdir/release-${bdevs[$i]}.log"; fi
            done
            bpids=(); bdevs=()
        fi
    done
    if (( ${#bpids[@]} > 0 )); then
        for i in "${!bpids[@]}"; do
            if wait "${bpids[$i]}"; then log "release[${bdevs[$i]}] OK"; RELEASED_OK+=("${bdevs[$i]}")
            else warn "release[${bdevs[$i]}] FAILED — see $logdir/release-${bdevs[$i]}.log"; fi
        done
    fi
}

[[ $# -gt 0 ]] || { echo "usage: $0 [-d DEVICE] [-t TAG] [-c CHANNEL] <phase...>   (phases: deps sync vendor overlay keys build release publish all; -d accepts a codename, 'all', or a comma-separated subset)"; exit 2; }

# Parse requested phases into booleans; the passes below enforce canonical order and the
# once/sequential-build/parallel-release/sequential-publish structure.
want_deps=false; want_sync=false; want_keys=false
want_vendor=false; want_overlay=false; want_build=false; want_release=false; want_publish=false
for p in "$@"; do
    case "$p" in
        all) want_deps=true; want_sync=true; want_keys=true
             want_vendor=true; want_overlay=true; want_build=true; want_release=true; want_publish=true ;;
        deps) want_deps=true ;;
        sync) want_sync=true ;;
        keys) want_keys=true ;;
        vendor) want_vendor=true ;;
        overlay) want_overlay=true ;;
        build) want_build=true ;;
        release) want_release=true ;;
        publish) want_publish=true ;;
        *) die "Unknown phase '$p'. Use: deps sync vendor overlay keys build release publish all" ;;
    esac
done

log "MAOS build — devices=[${DEVICES_LIST[*]}] tag=$TAG build=$BUILD channel=$OTA_CHANNEL tree=$TREE bucket=$R2_BUCKET"

# ---- Pass 1: device-independent phases, once ----
if $want_deps; then phase_deps; fi
if $want_sync; then phase_sync; fi
if $want_keys; then phase_keys; fi

# ---- Pass 2: build group (vendor/overlay/build), per device, sequential ----
BUILT_OK=()
build_group=false
if $want_vendor || $want_overlay || $want_build; then build_group=true; fi
if $build_group; then
    build_pinned=false
    for dev in "${DEVICES_LIST[@]}"; do
        log "=== Build $dev ==="
        if ( set -e; DEVICE="$dev"
             if $want_vendor;  then phase_vendor;  fi
             if $want_overlay; then phase_overlay; fi
             if $want_build;   then phase_build;   fi ); then
            BUILT_OK+=("$dev")
        else
            warn "Device $dev FAILED during build — skipping its release/publish."
        fi
        # Pin the batch build number from the first build so every device lands in one
        # releases/<build>/ dir (keeps date-based numbering consistent across the batch).
        if ! $build_pinned && $want_build && [[ -f "$TREE/out/soong/build_number.txt" ]]; then
            resolve_build_number
            export BUILD_NUMBER="$BUILD"
            build_pinned=true
        fi
    done
else
    # No build this run: release/publish operate on all selected devices.
    BUILT_OK=("${DEVICES_LIST[@]}")
fi

# ---- Pass 3: release, across devices, in parallel ----
RELEASED_OK=()
if $want_release; then
    resolve_build_number            # pin BUILD for all parallel release jobs
    reldevs=()
    if (( ${#BUILT_OK[@]} > 0 )); then reldevs=("${BUILT_OK[@]}"); fi
    if (( ${#reldevs[@]} == 0 )); then
        warn "No devices available to release."
    else
        unlock_keys_shared          # decrypt once; each job just reads keys/<device>
        for dev in "${reldevs[@]}"; do link_keys "$dev"; done
        run_release_parallel "${reldevs[@]}"
    fi
else
    if (( ${#BUILT_OK[@]} > 0 )); then RELEASED_OK=("${BUILT_OK[@]}"); fi
fi

# ---- Pass 4: publish, per device, sequential ----
PUBLISHED_OK=()
if $want_publish; then
    pubdevs=()
    if (( ${#RELEASED_OK[@]} > 0 )); then pubdevs=("${RELEASED_OK[@]}"); fi
    if (( ${#pubdevs[@]} == 0 )); then warn "No devices available to publish."; fi
    for dev in ${pubdevs[@]+"${pubdevs[@]}"}; do
        log "=== Publish $dev ==="
        if ( set -e; DEVICE="$dev"; phase_publish ); then
            PUBLISHED_OK+=("$dev")
        else
            warn "Device $dev FAILED during publish — continuing with the next device."
        fi
    done
fi

# ---- Summary ----
if $build_group || $want_release || $want_publish; then
    if   $want_publish; then success=("${PUBLISHED_OK[@]+"${PUBLISHED_OK[@]}"}"); laststage=publish
    elif $want_release; then success=("${RELEASED_OK[@]+"${RELEASED_OK[@]}"}");   laststage=release
    else                     success=("${BUILT_OK[@]+"${BUILT_OK[@]}"}");         laststage=build
    fi
    declare -A _ok=()
    for d in ${success[@]+"${success[@]}"}; do _ok[$d]=1; done
    log "Per-device summary through '$laststage' (${#DEVICES_LIST[@]} device(s)):"
    any_fail=false
    for d in "${DEVICES_LIST[@]}"; do
        if [[ -n "${_ok[$d]:-}" ]]; then printf '   %s: OK\n' "$d"
        else printf '   %s: FAILED\n' "$d"; any_fail=true; fi
    done
    if $any_fail; then log "Requested phases complete (with failures)."; exit 1; fi
fi

log "All requested phases complete."
