# MAOS build runbook (Linux)

End-to-end steps to build, sign, and ship MAOS. **This must run on Linux** (Debian/Ubuntu
recommended), with ~400 GB free disk, 32 GB+ RAM, and a fast connection. It cannot run on
Windows/macOS. Commands assume `bash`.

> Terminology: `$DEVICE` = Pixel codename (e.g. `shusky`), `$BUILD` = build number you
> choose (e.g. `2026080900`), `$KEYSDIR` = your keys dir (e.g. `~/.android-certs`).

---

## 0. One-time host setup

Follow GrapheneOS's official build-environment setup (packages, `repo`, adevtool, etc.).
Do not skip their prerequisites — MAOS is a thin overlay on top of a stock GrapheneOS
build, so if a plain GrapheneOS build works, MAOS will.

## 1. Sync the source + inject the MAOS overlay

```bash
mkdir grapheneos && cd grapheneos
repo init -u https://github.com/GrapheneOS/platform_manifest -b <RELEASE_BRANCH>

# Add the MAOS overlay via a local manifest (no fork of platform_manifest):
mkdir -p .repo/local_manifests
ln -s /path/to/MAOS/local_manifest.xml .repo/local_manifests/modern-apps.xml

repo sync -c -j"$(nproc)"
```

This lands the overlay at `vendor/modern-apps/`.

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

# Publish to the PUBLIC OTA repo (server proxies its latest release):
vendor/modern-apps/ota/publish-ota.sh -r vayun-mathur/MAOS-releases -t "$BUILD"
```

Make sure the server's `MAOS_OTA_GH` matches the repo you publish to.

## 10. Wire the OTA server

On the box running `location_share_server`, point DNS `ota.ma.vayunmathur.com` at it and
ensure its TLS cert covers that host. The server already routes that host to the OTA
proxy (`handlers/ota.rs`). No code change needed beyond deploying the updated binary.

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
