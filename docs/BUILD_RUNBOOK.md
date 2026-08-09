# MAOS build runbook (Linux)

End-to-end steps to build, sign, and ship MAOS. **This must run on Linux** (Debian/Ubuntu
recommended), with ~400 GB free disk, 32 GB+ RAM, and a fast connection. On Windows, use
WSL2 (see the section below). Commands assume `bash`.

> Terminology: `$DEVICE` = Pixel codename, `$BUILD` = build number you choose, `$KEYSDIR` =
> your keys dir (e.g. `~/.android-certs`).
>
> **Current target:** `$DEVICE = cheetah` (Pixel 7 Pro), base GrapheneOS tag
> **`2026080500`** (https://grapheneos.org/releases#2026080500).

---

## Building on WSL2 (Windows)

A GrapheneOS build runs well under WSL2 given enough disk/RAM. Do NOT build under `/mnt/c`
— AOSP needs a case-sensitive filesystem and heavy small-file I/O; use WSL2's native ext4
(your Linux home).

1. Install WSL2 (admin PowerShell, then reboot):
   ```powershell
   wsl --install -d Ubuntu
   wsl --update
   ```
2. Give it resources — create `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   memory=96GB
   processors=32
   swap=32GB
   ```
   Then `wsl --shutdown` and reopen Ubuntu.
3. Ensure the WSL virtual disk (`ext4.vhdx`) is on a drive with ~500 GB free. If your free
   space isn't on `C:`, move the distro with `wsl --export` / `wsl --import` to that drive.
4. Work inside `~/` (ext4), e.g. `~/maos` — never `/mnt/c/...`.

Everything below then runs unchanged inside the Ubuntu shell.

---

## 0. One-time host setup

Follow GrapheneOS's official build-environment setup for tag **2026080500** (packages,
`repo`, and **adevtool**, which extracts the Pixel vendor files). Do not skip their
prerequisites — MAOS is a thin overlay on a stock GrapheneOS build, so if a plain
GrapheneOS `cheetah` build works, MAOS will.

## 1. Sync the source + inject the MAOS overlay

```bash
mkdir -p ~/maos && cd ~/maos           # ext4, NOT /mnt/c
repo init -u https://github.com/GrapheneOS/platform_manifest -b refs/tags/2026080500

# Add the MAOS overlay via a local manifest (no fork of platform_manifest):
mkdir -p .repo/local_manifests
ln -s /path/to/MAOS/local_manifest.xml .repo/local_manifests/modern-apps.xml

repo sync -c -j"$(nproc)"
```

This lands the overlay at `vendor/modern-apps/`. (~150 GB download; takes a while.)

## 2. Confirm the stock module/project names

Names drift between GrapheneOS releases. Verify the `filter-out` list and (optional)
`<remove-project>` entries match this checkout:

```bash
grep -rn --include=*.mk -e 'Vanadium' -e 'Camera' -e 'PdfViewer' -e 'Apps' \
  -e 'Contacts' -e 'DeskClock' -e 'Calculator' -e 'Gallery2' -e 'DocumentsUI' \
  build/ device/ vendor/
```

Update `vendor/modern-apps/modern_apps.mk` if any differ. The build-time guard in that
file will fail the build if a stock app we meant to drop is still present.

## 3. Inherit the MAOS product config

In your device product makefile (`device/google/<board>/aosp_$DEVICE.mk` or the
GrapheneOS equivalent), **as the last inherit**:

```make
$(call inherit-product, vendor/modern-apps/modern_apps.mk)
```

This adds the 9 Modern Apps, filters out the stock apps, applies the overlays
(`config_defaultBrowser`, `config_documentsUiPackage`, Updater URL), the Files
privapp-permissions allowlist, and MAOS branding.

## 4. Populate the prebuilt APKs

Build the 9 apps from the Modern-Apps repo (or grab a release), then:

```bash
vendor/modern-apps/scripts/collect-apks.sh /path/to/Modern-Apps
```

## 5. Generate signing keys (once)

```bash
source build/envsetup.sh
vendor/modern-apps/keys/generate-keys.sh "$KEYSDIR"
```

Keep `$KEYSDIR` **offline and backed up**. Losing `releasekey`/`avb.pem` permanently
breaks OTA for installed devices.

## 6. Build

```bash
export DEVICE=cheetah          # Pixel 7 Pro
source build/envsetup.sh
lunch aosp_${DEVICE}-user      # or the GrapheneOS target for your device
m target-files-package
```

## 7. Sign

```bash
sign_target_files_apks -o -d "$KEYSDIR" \
  out/target/product/$DEVICE/obj/PACKAGING/target_files_intermediates/*-target_files-*.zip \
  signed-$DEVICE-$BUILD.zip
```

If AVB isn't picked up from `$KEYSDIR`, pass the AVB options explicitly
(`--avb_vbmeta_key`, `--avb_vbmeta_algorithm`, etc.) — see GrapheneOS's signing docs for
your device. Archive `signed-$DEVICE-$BUILD.zip` for future incrementals.

## 8. Produce a flashable factory image (for first install)

Use the standard AOSP `img_from_target_files` / GrapheneOS factory-image script on the
signed target-files, then flash via fastboot as usual.

## 9. Generate + publish OTA

```bash
# Full (and optional incremental from the previous signed target-files):
vendor/modern-apps/ota/build-ota.sh \
  -d "$DEVICE" -b "$BUILD" -c stable -k "$KEYSDIR" \
  -t signed-$DEVICE-$BUILD.zip \
  [-p signed-$DEVICE-$OLD_BUILD.zip -o "$OLD_BUILD"]

# Upload the zips + channel metadata to Cloudflare R2 (served at ota.ma.vayunmathur.com):
export R2_ACCESS_KEY_ID=...  R2_SECRET_ACCESS_KEY=...  R2_ACCOUNT_ID=...
vendor/modern-apps/ota/publish-ota.sh -b maos-ota
```

`publish-ota.sh` uploads the immutable zips first and the `$DEVICE-$CHANNEL` metadata
pointer last. Requires the `aws` CLI and the R2 env vars (see `ota/README.md`).

## 10. OTA hosting (Cloudflare R2)

`ota.ma.vayunmathur.com` is an **R2 bucket served via a Cloudflare custom domain** —
devices download directly from R2. There is no server component for OTA (R2 handles the
multi-GB payloads that GitHub Releases / the server's disk cannot). One-time setup:

1. Create the R2 bucket (e.g. `maos-ota`) and an API token with Object Read & Write.
2. Attach the custom domain `ota.ma.vayunmathur.com` (R2 → Settings → Custom Domains);
   Cloudflare provisions TLS.
3. Ensure any Cache Rule does **not** cache the `*-<channel>` metadata objects (the
   uploader already sets `Cache-Control: no-store` on them).

> The `handlers/ota.rs` proxy in `location_share_server` is now unused for this design
> (DNS points at R2, not the server) and can be removed; it is harmless dead code if left.

## 11. Test before trusting it

- **Sideload the full OTA** in recovery: `adb sideload <device>-ota_update-$BUILD.zip`
  (validates signing + `otacerts.zip` end to end).
- **In-app update**: install an older build, then let the Updater fetch from
  `ota.ma.vayunmathur.com`.
- **Incremental**: test specifically from the previous build (deltas fail differently
  than full OTAs).
- **Key isolation**: confirm a MAOS-signed device rejects a GrapheneOS OTA and vice
  versa.

---

## De-branding checklist (Part of "cannot ship as GrapheneOS")

`maos_branding.mk` covers build.prop identity. Also overlay the user-visible strings:

```bash
grep -rn "GrapheneOS" packages/apps/Settings/ device/ vendor/ | grep -i string
```

Overlay the "About phone" / Settings strings and swap boot logo/wallpaper assets under
`vendor/modern-apps/overlay/` for the relevant packages. Attestation (Auditor) is pinned
to GrapheneOS's keys/server and won't pass under a fork — disable or self-host it.
