# MAOS — Modern Apps OS

A GrapheneOS-derived Android OS that ships the [Modern Apps](https://github.com/vayun-mathur)
ecosystem (`com.vayunmathur.*`) in place of the stock GrapheneOS/AOSP userspace apps.

This repository is the **overlay** — the single repo you maintain. It is added to a
GrapheneOS source tree at `vendor/modern-apps/` via a `repo` local manifest. There are
**no long-lived AOSP forks**: additions, removals, and config are all expressed as
overlays. (Full design rationale lives in `GRAPHENEOS_FORK_PLAN.md` in the Modern-Apps
repo.)

## Apps swapped

| Modern App | Package | Replaces |
| --- | --- | --- |
| Web | `com.vayunmathur.web` | Vanadium (browser only; WebView kept) |
| Camera | `com.vayunmathur.camera` | GrapheneOS Camera |
| PDF | `com.vayunmathur.pdf` | PdfViewer |
| Contacts | `com.vayunmathur.contacts` | AOSP Contacts |
| Calculator | `com.vayunmathur.calculator` | AOSP Calculator |
| Clock | `com.vayunmathur.clock` | AOSP DeskClock |
| Files | `com.vayunmathur.files` | **DocumentsUI** (Files also takes over the SAF role — see below) |
| Photos | `com.vayunmathur.photos` | AOSP Gallery |
| App Store | `com.vayunmathur.appstore` | GrapheneOS Apps |

## Layout

```
Android.bp                            # android_app_import per app (Files: privileged)
modern_apps.mk                        # PRODUCT_PACKAGES += ours; filter-out stock; overlays; privapp
privapp-permissions-modern-apps.xml   # MANAGE_DOCUMENTS for Files
overlay/                              # static frameworks/base overlay
  frameworks/base/core/res/res/values/config.xml   # config_defaultBrowser, config_documentsUiPackage
prebuilts/                            # release APKs (git-ignored; populated by script)
scripts/collect-apks.sh              # copies Modern-Apps release APKs into prebuilts/
local_manifest.xml                    # adds this repo to the GrapheneOS tree
```

## Usage

1. Set up a GrapheneOS build environment and choose a release branch.
2. Before `repo sync`, symlink the local manifest:
   ```bash
   mkdir -p .repo/local_manifests
   ln -s /path/to/MAOS/local_manifest.xml .repo/local_manifests/modern-apps.xml
   repo sync
   ```
   This lands the overlay at `vendor/modern-apps/`.
3. Inherit the product config **last** in your device makefile
   (`device/.../aosp_<device>.mk`):
   ```make
   $(call inherit-product, vendor/modern-apps/modern_apps.mk)
   ```
4. Populate the prebuilt APKs (build them from Modern-Apps first):
   ```bash
   vendor/modern-apps/scripts/collect-apks.sh /path/to/Modern-Apps
   ```
5. Build, sign with your own keys, and rebrand (you cannot ship as "GrapheneOS").

## Notes

- **Vanadium stays installed** as the system WebView provider; only the default *browser*
  role moves to Web (via `config_defaultBrowser`). Our Web app relies on system WebView.
- **Files absorbs DocumentsUI.** DocumentsUI is the system Storage Access Framework (SAF)
  picker (`OPEN_DOCUMENT` / `CREATE_DOCUMENT` / `OPEN_DOCUMENT_TREE` / `GET_CONTENT`), not
  just a file manager. Removing it requires Files to take over that role **in the system
  build only**:
  - `config_documentsUiPackage` is overlaid to `com.vayunmathur.files`.
  - Files ships as a **priv-app** holding `MANAGE_DOCUMENTS` (see the privapp allowlist).
  - The SAF picker is implemented in the Files app (Modern-Apps repo) as a
    `DocumentPickerActivity`. It is the **same APK** as the F-Droid build — no separate flavor. The
    picker component ships disabled and a small `Application` enables it only when `MANAGE_DOCUMENTS`
    is granted (i.e. only in MAOS), so the userspace Files app is unchanged.
- **APKs are `presigned`** so each keeps its `com.vayunmathur` certificate, preserving the
  app-store update chain. The *OS* is signed with your own platform keys.
- **Silent-breakage guard:** `modern_apps.mk` fails the build if any stock module we meant
  to drop is still present in `PRODUCT_PACKAGES` (guards against upstream renames).
- Alternative to `filter-out`: AOSP's `overrides:` field on `android_app_import` also
  removes a named module. We use `filter-out` for a single, explicit removal list.

## OTA

MAOS uses the standard GrapheneOS/AOSP A/B OTA flow (`update_engine` + a forked/overlaid
Updater pointed at your own signed release server). See the OTA section of
`GRAPHENEOS_FORK_PLAN.md`.
