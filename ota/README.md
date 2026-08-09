# MAOS OTA

How over-the-air updates flow, and the scripts that produce them.

## Pipeline

```
signed target-files ──build-ota.sh──▶ full + incremental OTA zips + channel metadata
        │                                          │
        │                                          ▼
        │                               publish-ota.sh ──▶ PUBLIC GitHub Release (latest)
        │                                                          │
        ▼                                                          ▼
  (kept for next                              ota.ma.vayunmathur.com proxies
   incremental)                               /latest/download/<file>  (location_share_server)
                                                                   │
                                                                   ▼
                                                        Updater on device
```

- **`build-ota.sh`** turns a *signed* target-files zip into `DEVICE-ota_update-BUILD.zip`
  (full), optionally `DEVICE-incremental-OLD-NEW.zip`, and a `DEVICE-CHANNEL` metadata
  file. Signed with your `releasekey`.
- **`publish-ota.sh`** uploads those to a **public** GitHub Release marked *latest*.
- **`location_share_server`** (`handlers/ota.rs`) serves `https://ota.ma.vayunmathur.com/<file>`
  by streaming from `releases/latest/download/<file>` of that repo. Set `MAOS_OTA_GH` on
  the server to the repo you publish to (defaults to `vayun-mathur/MAOS`).
- The **Updater** app polls `https://ota.ma.vayunmathur.com/<device>-<channel>` then
  downloads the referenced zip (see `../updater/README.md`).

## Keep every release's signed target-files

Incrementals diff the previous signed target-files against the new one. Archive each
release's `signed-*.zip` so you can pass it as `-p` next time. Without it you can still
ship a full OTA, just not a delta.

## Metadata format

`build-ota.sh` writes `BUILD TIMESTAMP CHANNEL` (one line). This must match whatever your
Updater version parses — confirm against the pinned source and adjust both sides
together if needed.

## Payloads are proxied, not stored

Nothing is stored on the OTA host; it streams from GitHub Releases (mirrors how the
F-Droid repo proxies APKs). The release repo must be **public** so the server can fetch
without auth (or run the server with a token and keep it private).

See `../docs/BUILD_RUNBOOK.md` for the full build → sign → OTA → publish sequence.
