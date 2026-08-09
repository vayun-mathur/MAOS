# MAOS build runbook — Pixel 7 Pro (cheetah)

Everything needed to build, sign, and publish MAOS for the **Pixel 7 Pro (`cheetah`)** on
GrapheneOS base tag **`2026080500`**, from a Windows machine using WSL2. This is fully
self-contained — you shouldn't need any other page.

MAOS is a thin overlay on a stock GrapheneOS build: it swaps the default userspace apps for
the Modern Apps, rebrands, and points OTA/updates at your own server. So if a plain
GrapheneOS `cheetah` build works, MAOS will.

> Conventions used below:
> - `$BUILD` = the build number you pick (e.g. `2026080900`).
> - Work happens in `~/maos` inside WSL2's ext4 — **never** under `/mnt/c` (AOSP needs a
>   case-sensitive filesystem and fast small-file I/O).
> - Requirements: ~400 GB free, 32 GB+ RAM (you have plenty), fast connection.

---

## 1. Set up WSL2 (Windows)

In an **Administrator** PowerShell:

```powershell
wsl --install -d Ubuntu
wsl --update
```

Reboot when prompted, then launch **Ubuntu** and create your Linux user.

Give WSL resources — create `C:\Users\vayun\.wslconfig`:

```ini
[wsl2]
memory=96GB
processors=32
swap=32GB
```

Apply it from PowerShell: `wsl --shutdown`, then reopen Ubuntu.

The WSL virtual disk grows on `C:` (you have ~1.1 TB free there — fine). Everything from
here runs **inside the Ubuntu shell**.

---

## 2. Install build dependencies (Ubuntu 24.04 / Debian 12)

```bash
sudo apt update
sudo apt install -y \
  repo yarnpkg zip unzip rsync git gnupg openssh-client \
  python3 python-is-python3 diffutils hostname openssl \
  libfreetype6 fontconfig fonts-dejavu-core \
  build-essential curl awscli
```

Add the sbin dirs to PATH (AOSP tools expect them):

```bash
echo 'export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin' >> ~/.bashrc
source ~/.bashrc
```

Install **Node.js 24 + yarn** (needed by adevtool for vendor extraction):

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
. ~/.nvm/nvm.sh
nvm install 24
npm install -g yarn
```

(We keep Vanadium as a prebuilt WebView provider, so you do **not** build Chromium — the
32-bit/gperf Chromium deps are unnecessary.)

---

## 3. Download the GrapheneOS source (tag 2026080500)

```bash
mkdir -p ~/maos && cd ~/maos
repo init -u https://github.com/GrapheneOS/platform_manifest.git -b refs/tags/2026080500
```

Verify the manifest signature:

```bash
curl https://grapheneos.org/allowed_signers > ~/.ssh/grapheneos_allowed_signers
cd .repo/manifests
git config gpg.ssh.allowedSignersFile ~/.ssh/grapheneos_allowed_signers
git verify-tag $(git describe)
cd ../..
```

---

## 4. Inject the MAOS overlay via a local manifest

The overlay lands at `vendor/modern-apps/` during sync — no fork of `platform_manifest`.

```bash
mkdir -p .repo/local_manifests
```

Create `.repo/local_manifests/modern-apps.xml` with exactly this content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="maos-github" fetch="https://github.com/vayun-mathur/" />
  <project path="vendor/modern-apps" name="MAOS" remote="maos-github" revision="main" />
</manifest>
```

> The MAOS repo is **private**, so `repo sync` needs GitHub credentials to clone it. Either
> make the repo public, or set up a credential helper in WSL first:
> ```bash
> git config --global credential.helper store
> # then a one-time authenticated clone caches the token:
> git clone https://github.com/vayun-mathur/MAOS.git /tmp/maos-cred-test && rm -rf /tmp/maos-cred-test
> ```

Now sync everything (~150 GB; resumable — just rerun if it drops):

```bash
repo sync -j8
```

This clones the OS **and** `vendor/modern-apps/`.

---

## 5. Set up the build environment

```bash
source build/envsetup.sh
```

---

## 6. Extract Pixel vendor files (adevtool)

One-time per checkout. This downloads Google's `cheetah` images and extracts the vendor
blobs the build needs:

```bash
yarn --cwd vendor/adevtool/ install
adevtool generate-all -d cheetah
```

---

## 7. Wire in + validate the MAOS overlay

**7a. Populate the prebuilt APKs.** The Modern Apps ship as prebuilt APKs; they're
git-ignored in the overlay, so copy them in from a Modern-Apps build or release. If you have
the Modern-Apps repo checked out (with built release APKs, or its `distribution_apks/`):

```bash
vendor/modern-apps/scripts/collect-apks.sh /path/to/Modern-Apps
```

This fills `vendor/modern-apps/prebuilts/` with the 9 APKs
(web, camera, pdf, contacts, calculator, clock, files, photos, appstore).

**7b. Confirm the stock module names** the overlay filters out match this tag:

```bash
grep -rn --include=*.mk -e 'Vanadium' -e 'Camera' -e 'PdfViewer' -e 'Apps' \
  -e 'Contacts' -e 'DeskClock' -e 'Calculator' -e 'Gallery2' -e 'DocumentsUI' \
  build/ device/ vendor/ | grep -i 'PRODUCT_PACKAGES'
```

If any module name differs, edit the `$(filter-out ...)` list in
`vendor/modern-apps/modern_apps.mk`. (A build-time guard in that file fails the build if a
stock app you meant to drop is still present, so you'll be told.)

**7c. Inherit the MAOS product config** — find cheetah's product makefile and append the
inherit as the **last** line so its `filter-out` sees the stock apps:

```bash
find device/google -name '*cheetah*.mk'
# edit the product makefile for cheetah (e.g. device/google/pantah/aosp_cheetah.mk) and add:
#   $(call inherit-product, vendor/modern-apps/modern_apps.mk)
```

**7d. Point the Updater at your server.** Set the OTA URL in the tree (most reliable):

```bash
grep -rn 'releases.grapheneos.org' packages/apps/Updater/res/values/config.xml
# change that URL to:  https://ota.ma.vayunmathur.com
```

---

## 8. Generate signing keys (once, keep OFFLINE)

These are the OS keys — separate from the app signing keys (the Modern Apps keep their own
`com.vayunmathur` cert). Losing these permanently breaks OTA/verified boot for installed
devices. Use a passphrase; keep the directory offline and backed up.

```bash
mkdir -p keys/cheetah && cd keys/cheetah
CN=MAOS
../../development/tools/make_key releasekey    "/CN=$CN/"
../../development/tools/make_key platform      "/CN=$CN/"
../../development/tools/make_key shared        "/CN=$CN/"
../../development/tools/make_key media         "/CN=$CN/"
../../development/tools/make_key networkstack  "/CN=$CN/"
../../development/tools/make_key bluetooth     "/CN=$CN/"
../../development/tools/make_key sdk_sandbox   "/CN=$CN/"
../../development/tools/make_key gmscompat_lib "/CN=$CN/"
../../development/tools/make_key nfc           "/CN=$CN/"

# Verified Boot key (RSA-4096) + its public metadata blob:
openssl genrsa 4096 | openssl pkcs8 -topk8 -scrypt -out avb.pem
../../external/avb/avbtool.py extract_public_key --key avb.pem --output avb_pkmd.bin

# OpenSSH key used to sign factory images (use the same passphrase):
ssh-keygen -t ed25519 -f id_ed25519
cd ../..
```

Optional but recommended — (re)encrypt the keys at rest:

```bash
script/encrypt-keys keys/cheetah
```

---

## 9. Build

```bash
export OFFICIAL_BUILD=true        # includes the Updater app (URL set in 7d)
lunch cheetah-cur-user            # production 'user' build
rm -rf out                        # clean slate for a production build
m vendorbootimage vendorkernelbootimage target-files-package
```

> The Pixel 7 Pro specifically needs `vendorbootimage vendorkernelbootimage
> target-files-package` (not just `target-files-package`). This build takes a while even on
> a Threadripper; LTO linking is the memory-heavy part.

---

## 10. Generate signed factory images + full OTA

```bash
m otatools-package
script/finalize.sh
script/generate-release.sh cheetah "$BUILD"
```

Outputs land in `releases/$BUILD/release-cheetah-$BUILD/`:

```
cheetah-ota_update-$BUILD.zip        # full OTA (Updater app)
cheetah-factory-$BUILD.zip           # factory image (first install / web installer)
cheetah-factory-$BUILD.zip.sig
cheetah-testing  cheetah-beta  cheetah-stable   # channel metadata
```

`generate-release.sh` will prompt for your key passphrase (from step 8). The channel
metadata is GrapheneOS's native format, which the (forked/repointed) Updater understands —
so there's nothing custom to produce.

---

## 11. Cloudflare R2 (one-time hosting setup)

You need two things served from R2:
- **OTA** at `https://ota.ma.vayunmathur.com/<file>` (Updater app).
- **Web-installer** factory images under `https://ota.ma.vayunmathur.com/factory/cheetah/latest/`.

Setup:
1. Create an R2 bucket (e.g. `maos-ota`).
2. R2 → Settings → **Custom Domains** → attach `ota.ma.vayunmathur.com` (Cloudflare issues TLS).
3. R2 → Manage API Tokens → create a token with **Object Read & Write** on the bucket.
4. Add a **CORS policy** on the bucket so the installer page (served from
   `ma.vayunmathur.com`) can fetch images cross-origin:
   ```json
   [
     {
       "AllowedOrigins": ["https://ma.vayunmathur.com"],
       "AllowedMethods": ["GET", "HEAD"],
       "AllowedHeaders": ["range"],
       "ExposeHeaders": ["content-length", "content-range", "accept-ranges", "etag"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```
5. Add a **Cache Rule** that bypasses cache for the channel-metadata files (the flat
   `cheetah-stable` / `cheetah-beta` names, i.e. paths not ending in `.zip`) so devices
   never see a stale pointer.

Point the AWS CLI at R2 (used for uploads below):

```bash
export R2_ACCESS_KEY_ID=...   R2_SECRET_ACCESS_KEY=...   R2_ACCOUNT_ID=...
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required   # R2 multipart compatibility
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
R2="aws s3 --endpoint-url https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
```

---

## 12. Publish the OTA (Updater channel)

Upload the OTA **zip first**, then the channel-metadata pointer **last**, so a device
polling mid-upload never sees a pointer to a missing file:

```bash
cd releases/$BUILD/release-cheetah-$BUILD

$R2 cp cheetah-ota_update-$BUILD.zip s3://maos-ota/ \
  --content-type application/zip \
  --cache-control 'public, max-age=31536000, immutable'

$R2 cp cheetah-stable s3://maos-ota/ \
  --content-type 'text/plain; charset=utf-8' \
  --cache-control 'no-store, must-revalidate'
```

Now `ro.maos.channel=stable` devices poll `https://ota.ma.vayunmathur.com/cheetah-stable`
and pull `cheetah-ota_update-$BUILD.zip`. For a `testing` channel first, upload
`cheetah-testing` instead and set the device to it with
`adb shell setprop sys.update.channel testing`.

---

## 13. Publish the factory image for the web installer

The web installer flashes per-partition images described by a `manifest.json`. Turn the
factory zip into that layout and upload it:

```bash
~/maos/vendor/modern-apps/installer/prepare-factory.sh \
  -d cheetah -b "$BUILD" \
  -f releases/$BUILD/release-cheetah-$BUILD/cheetah-factory-$BUILD.zip \
  -P plan.json
```

This uploads to `factory/cheetah/$BUILD/` and `factory/cheetah/latest/` (the installer
reads `latest`).

> **Locking the bootloader with your own keys (important for cheetah):** to re-lock after
> flashing MAOS, the device must trust your AVB key. Your flash `plan.json` must include a
> step that flashes `avb_custom_key` from `keys/cheetah/avb_pkmd.bin` before the lock step,
> mirroring the factory image's own `flash-all` sequence. Without it, locking will fail /
> can brick the device. Model the plan on the `flash-all` script inside the factory zip.

---

## 14. Test before trusting a release

- **Sideload the full OTA** in recovery (validates signing + `otacerts.zip` end-to-end):
  ```bash
  adb reboot recovery    # then choose "Apply update from ADB"
  adb sideload releases/$BUILD/release-cheetah-$BUILD/cheetah-ota_update-$BUILD.zip
  ```
- **Web installer:** open `https://ma.vayunmathur.com/os/install` in Chrome/Edge with the
  Pixel 7 Pro in bootloader mode; it should auto-detect "Pixel 7 Pro (cheetah)", then
  Unlock → Download → Flash → Lock.
- **In-app Updater:** install an older build, let the Updater fetch from your server.
- **Incremental** (below): test specifically from the previous build.
- **Key isolation:** confirm a MAOS-signed device rejects a GrapheneOS OTA and vice versa.

To flash the factory image directly for first install (unlock first):

```bash
adb reboot bootloader
fastboot flashing unlock
cd releases/$BUILD/release-cheetah-$BUILD
unzip cheetah-factory-$BUILD.zip && cd cheetah-factory-$BUILD
./flash-all.sh
```

---

## 15. Incremental (delta) updates

Deltas ship only the changes between two builds. Keep each release's signed target-files so
you can diff against it. With both builds under `releases/`:

```
releases/
├── <OLD_BUILD>/release-cheetah-<OLD_BUILD>
└── <NEW_BUILD>/release-cheetah-<NEW_BUILD>
```

```bash
script/generate-delta.sh cheetah <OLD_BUILD> <NEW_BUILD>
# then upload the resulting incremental zip alongside the OTA (no extra metadata needed):
$R2 cp releases/<NEW_BUILD>/release-cheetah-<NEW_BUILD>/cheetah-incremental-<OLD_BUILD>-<NEW_BUILD>.zip \
  s3://maos-ota/ --content-type application/zip \
  --cache-control 'public, max-age=31536000, immutable'
```

The Updater automatically prefers a delta from the installed version when one exists.

---

## 16. Rebranding & attestation notes

- `vendor/modern-apps/maos_branding.mk` (inherited in 7c) sets the MAOS `PRODUCT_*` /
  `ro.maos.*` identity. To fully de-brand the UI, also overlay the Settings "About phone"
  strings and swap boot logo/wallpaper assets under `vendor/modern-apps/overlay/`:
  ```bash
  grep -rn 'GrapheneOS' packages/apps/Settings/ | grep -i string
  ```
- Attestation (Auditor / remote attestation) is pinned to GrapheneOS's keys+server and
  won't pass under a self-signed fork — expected. Disable or self-host it if you need it.
- Because the build is self-signed, stock Play Integrity won't pass either (also expected).

---

## 17. Updating to a newer GrapheneOS tag later

```bash
cd ~/maos
repo init -u https://github.com/GrapheneOS/platform_manifest.git -b refs/tags/<NEW_TAG>
repo sync -j8 --force-sync
# re-verify module names (step 7b), re-run adevtool if the device firmware changed,
# then rebuild (step 9) and re-release (step 10).
```

Reuse the **same** `keys/cheetah/` — regenerating keys forces a factory reset on every
device and breaks OTA continuity.
