# Updater (MAOS)

MAOS ships the first-party **MA Updater** app (`com.vayunmathur.updater`,
module `ModernAppsUpdater` in `../Android.bp`). It **replaces** the GrapheneOS
Updater outright via `overrides: ["Updater"]` — the GrapheneOS app is displaced,
not configured. There is no overlay, fork, or URL patch for the stock Updater;
do not re-add one.

## How the MA Updater finds the server

The app reads the `ro.maos.ota.server` system property, set to
`https://ota.maproj.org` in `../maos_branding.mk`, and falls back to that same
URL when the property is empty (Modern-Apps `updater/.../SystemBuild.kt`).

For device `$DEVICE` on channel `$CHANNEL` (e.g. `stable`), it polls:

- **Metadata:** `GET https://ota.maproj.org/$DEVICE-$CHANNEL`
- **Payload:** the OTA zip referenced by that metadata, applied to the
  inactive A/B slot via `update_engine` after local signature verification.

## Publishing

`build-maos.sh`'s `publish` phase uploads the release OTA zip first
(immutable cache) and the `$DEVICE-$CHANNEL` metadata last (`no-store`) to
the R2 bucket `maos`, which `ota.maproj.org` serves. See `../ota/README.md`.
Keep the channel names the app offers in sync with the ones published.
