# Updater configuration (MAOS)

MAOS reuses the GrapheneOS Updater app but points it at our own OTA server,
`https://ota.ma.vayunmathur.com` — a **Cloudflare R2 bucket** exposed via a custom domain,
which serves the signed OTA zips + channel metadata directly (uploaded by
`ota/publish-ota.sh`; see `../ota/README.md`).

## What the Updater fetches

For device `$DEVICE` on channel `$CHANNEL` (e.g. `stable`), it requests:

- **Metadata:** `GET https://ota.ma.vayunmathur.com/$DEVICE-$CHANNEL`
- **Full OTA:** `GET https://ota.ma.vayunmathur.com/$DEVICE-ota_update-$BUILD.zip`
- **Incremental:** `GET https://ota.ma.vayunmathur.com/$DEVICE-incremental-$OLD-$NEW.zip`

Those filenames are produced by `ota/build-ota.sh` and uploaded to the release by
`ota/publish-ota.sh`. The metadata line format is defined there and must match whatever
your Updater version parses (GrapheneOS uses a short space-separated line —
`BUILD TIMESTAMP CHANNEL` in our `build-ota.sh`).

## Two things to change in the Updater

1. **Server URL.** GrapheneOS hardcodes `https://releases.grapheneos.org`. Find it and
   replace it with `https://ota.ma.vayunmathur.com`:

   ```bash
   grep -rn "releases.grapheneos.org" packages/apps/Updater/
   ```

   If it resolves to a **string resource**, prefer overlaying it (no fork) — see
   `overlay/` below. If it's a `const`/`BuildConfig` value in code, you need a small
   fork of `packages/apps/Updater` (pull it in via the local manifest; see the main
   fork plan's "fallback: when a real fork is unavoidable").

2. **Certificate pinning.** GrapheneOS pins its server's certificate. `ota.ma.vayunmathur.com`
   uses a Cloudflare-managed certificate (and Cloudflare may rotate it), so either remove the
   pin or pin to the Cloudflare/issuer cert. Check the Updater's `network_security_config` /
   any `CertificatePinner`:

   ```bash
   grep -rn "pin-set\|CertificatePinner\|network_security_config" packages/apps/Updater/
   ```

## Overlay (preferred, if the URL is a resource)

`overlay/packages/apps/Updater/res/values/config.xml` in this repo overlays the server
URL. **Verify the string name** against your pinned Updater source before relying on it
— an overlay with the wrong resource name silently does nothing (it won't fail the
build). Update the name to match, then confirm the built Updater points at
`ota.ma.vayunmathur.com`.

## Channels

`build-ota.sh` publishes per-channel metadata (`$DEVICE-stable`, `$DEVICE-beta`, ...).
Keep the channel names the Updater offers in sync with the ones you publish.
