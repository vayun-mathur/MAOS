# MAOS build runbook — Pixel 7 Pro (cheetah)

Build and publish MAOS for the **Pixel 7 Pro (`cheetah`)** on GrapheneOS base tag
**`2026080500`** from a Windows machine. The whole pipeline (install deps, sync source,
extract vendor files, apply the MAOS overlay, generate/use signing keys, build, sign, and
publish OTA + web-installer artifacts) is automated by **`build-maos.sh`**. This runbook is
just the three things you do by hand: **set up WSL2**, **create the encrypted keystore**,
and **run the script**.

---

## 1. Set up WSL2 (Windows)

In an **Administrator** PowerShell:

```powershell
wsl --install -d Ubuntu-24.04
wsl --update
```

> Use **Ubuntu 24.04 LTS** (a GrapheneOS-supported build OS). 25.10 ("resolute") may work
> but isn't supported.

Reboot, launch Ubuntu, create your Linux user, then create `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=96GB
processors=32
swap=32GB
# Share the host network stack so WSL inherits working connectivity behind a
# corporate VPN / IPv4-only ISP (otherwise apt/git/repo can't reach the internet).
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
firewall=true
```

Apply it: `wsl --shutdown` in PowerShell, then reopen Ubuntu. Sanity-check networking:

```bash
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://github.com   # expect 200
```

The WSL virtual disk grows on `C:` (needs ~400 GB free). Always work inside your Linux home
(`~`, ext4) — **never** `/mnt/c` (AOSP needs a case-sensitive filesystem).

---

## 2. Get the build script

The overlay repo is private, so authenticate git once, then clone it for the script:

```bash
sudo apt update && sudo apt install -y git
git config --global credential.helper store
git clone https://github.com/vayun-mathur/MAOS.git ~/MAOS   # prompts for GitHub creds once
```

---

## 3. One-time Cloudflare R2 setup (for publishing)

Needed only for the `publish` phase.

1. Create an R2 bucket (e.g. `maos-ota`).
2. R2 → Settings → **Custom Domains** → attach `ota.ma.vayunmathur.com` (Cloudflare issues TLS).
3. R2 → Manage API Tokens → create a token with **Object Read & Write** on the bucket.
4. Add a bucket **CORS policy** so the installer page (`ma.vayunmathur.com`) can fetch images:
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
5. Add a **Cache Rule** that bypasses cache for the channel-metadata files (paths not ending
   in `.zip`) so devices never see a stale build pointer.

---

## 4. Configure the environment

In the Ubuntu shell (add to `~/.bashrc` to persist), set the passphrase for the encrypted
keystore and your R2 credentials:

```bash
export MAOS_KEYS_PASSPHRASE='<a strong passphrase you choose>'   # unlocks the keystore
export R2_ACCOUNT_ID='<cloudflare account id>'
export R2_ACCESS_KEY_ID='<r2 token key id>'
export R2_SECRET_ACCESS_KEY='<r2 token secret>'
```

Optional:

```bash
# export MODERN_APPS_SRC=/path/to/Modern-Apps   # else the 9 APKs are downloaded from GitHub
```

Device, tag, and OTA channel are **command-line flags** on the script (not env vars),
defaulting to `cheetah` / `2026080500` / `stable`. The AOSP checkout (`~/maos`), the R2
bucket (`maos`), and the release build number (always the GrapheneOS tag) are fixed.

The keystore is written to `~/maos-keys/<device>.keys.tar.gz.scrypt` (scrypt + AES-256,
encrypted with your passphrase). **Back that file up and keep the passphrase safe** — losing
either permanently breaks OTA/verified boot for every installed device.

---

## 5. Create the encrypted keystore + build

Run the pipeline. The first run generates the signing keys and encrypts them into the
keystore automatically (the `keys` phase), then builds, signs, and publishes:

```bash
~/MAOS/build-maos.sh all                       # Pixel 7 Pro (cheetah), tag 2026080500
# other devices/tags/channels via flags:
# ~/MAOS/build-maos.sh -d panther -t 2026080500 -c beta all
```

Phases run in order: `deps → sync → vendor → overlay → keys → build → release → publish`.
It's **resumable** — rerun `all`, or run phases individually, e.g.:

```bash
~/MAOS/build-maos.sh deps sync vendor overlay   # prep (long: ~150 GB sync)
~/MAOS/build-maos.sh keys                        # create the encrypted keystore
~/MAOS/build-maos.sh build release publish       # build → sign → upload
```

How the keys are handled each run: the encrypted keystore is decrypted **only into RAM**
(`/dev/shm`), symlinked in for signing, and shredded on exit — the private keys never touch
disk in the clear.

When `publish` finishes, the OTA is live at
`https://ota.ma.vayunmathur.com/cheetah-<channel>` and the web installer can flash the build
from `https://ma.vayunmathur.com/os/install`.

---

## 6. Test the release

- **Web installer:** open `https://ma.vayunmathur.com/os/install` in Chrome/Edge with the
  Pixel 7 Pro in bootloader mode; it auto-detects "Pixel 7 Pro (cheetah)", then
  Unlock → Download → Flash → Lock.
- **Sideload the full OTA** (validates signing end-to-end):
  ```bash
  adb reboot recovery      # choose "Apply update from ADB"
  adb sideload ~/maos/releases/$BUILD/release-cheetah-$BUILD/cheetah-ota_update-$BUILD.zip
  ```
- **In-app Updater:** install an older build, let it update from your server.

---

## Notes / caveats

- **Bootloader re-locking** with your own keys needs the device to trust your AVB key. The
  `publish` phase's factory-image prep should include flashing `avb_custom_key` (from your
  keystore's `avb_pkmd.bin`) before the lock step; for a production release, pass a
  `plan.json` mirroring the factory image's own `flash-all` sequence. Locking with a wrong
  image can hard-brick the device.
- **Rebranding/attestation:** MAOS build.prop identity is set automatically. Auditor / remote
  attestation and stock Play Integrity won't pass on a self-signed fork (expected).
- **Updating to a newer GrapheneOS tag:** set `TAG=<new>` and rerun the phases. Reuse the
  **same** keystore — regenerating keys forces a factory reset and breaks OTA continuity.
- **Corporate machine/network:** if this is a work machine, a full AOSP build pulls ~150 GB
  through that network and stores your personal signing keys locally — confirm that's within
  acceptable-use, or use a personal machine / cloud Linux VM.
