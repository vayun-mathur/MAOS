# MAOS OTA

How over-the-air updates flow, and the scripts that produce them.

## Pipeline

```
signed target-files ──build-ota.sh──▶ full + incremental OTA zips + channel metadata
        │                                          │
        │                                          ▼
        │                               publish-ota.sh ──▶ Cloudflare R2 bucket
        │                                                          │
        ▼                                                          ▼
  (kept for next                              ota.ma.vayunmathur.com  (R2 custom domain,
   incremental)                               serves objects directly)
                                                                   │
                                                                   ▼
                                                        Updater on device
```

- **`build-ota.sh`** turns a *signed* target-files zip into `DEVICE-ota_update-BUILD.zip`
  (full), optionally `DEVICE-incremental-OLD-NEW.zip`, and a `DEVICE-CHANNEL` metadata
  file. Signed with your `releasekey`.
- **`publish-ota.sh`** uploads those to a **Cloudflare R2** bucket (S3-compatible, via the
  `aws` CLI). Zips go up first; the channel-metadata pointer goes up last.
- **`ota.ma.vayunmathur.com`** is that R2 bucket exposed via a Cloudflare custom domain, so
  an object keyed `<file>` is served at `https://ota.ma.vayunmathur.com/<file>`. Devices
  download straight from R2 — **no GitHub Release and no `location_share_server` proxy are
  involved** (R2 handles the multi-GB payloads that GitHub Releases / the server's disk
  can't).
- The **Updater** app polls `https://ota.ma.vayunmathur.com/<device>-<channel>` then
  downloads the referenced zip (see `../updater/README.md`).

## Credentials (never commit)

`publish-ota.sh` reads R2 credentials from the environment:

| Var | Meaning |
| --- | --- |
| `R2_ACCESS_KEY_ID` | R2 API token access key id |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_ACCOUNT_ID` | Cloudflare account id (builds the endpoint), **or** |
| `R2_ENDPOINT` | full endpoint URL (overrides `R2_ACCOUNT_ID`) |
| `R2_BUCKET` | bucket name (default `maos-ota`; or pass `-b`) |

The endpoint defaults to `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com`. Create the
API token in the Cloudflare dashboard (R2 → Manage API Tokens) with **Object Read & Write**
on the target bucket.

## Cloudflare setup (one-time)

1. Create the R2 bucket (e.g. `maos-ota`).
2. Attach the custom domain `ota.ma.vayunmathur.com` to it (R2 → Settings → Custom Domains).
   Cloudflare provisions TLS automatically.
3. The object `Cache-Control` headers set by `publish-ota.sh` (immutable zips, `no-store`
   metadata) are honored by Cloudflare's cache. If you add a Cache Rule, make sure it does
   **not** cache the `*-<channel>` metadata objects, or devices will see stale builds.

## Keep every release's signed target-files

Incrementals diff the previous signed target-files against the new one. Archive each
release's `signed-*.zip` so you can pass it as `-p` next time. Without it you can still
ship a full OTA, just not a delta.

## Metadata format

`build-ota.sh` writes `BUILD TIMESTAMP CHANNEL` (one line). This must match whatever your
Updater version parses — confirm against the pinned source and adjust both sides together
if needed.

See `../docs/BUILD_RUNBOOK.md` for the full build → sign → OTA → publish sequence.
