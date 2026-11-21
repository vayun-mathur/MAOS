# MAOS OTA

How over-the-air updates flow. There are no standalone OTA scripts in this
directory: building and publishing OTAs is the `release` and `publish` phases
of `../build-maos.sh`.

## Pipeline

```
build-maos.sh build ──▶ target-files ──release──▶ signed OTA zip + factory image
                                                      │
                                                 publish (per device)
                                                      ▼
                                          Cloudflare R2 bucket `maos`
                                                      │
                                          ota.maproj.org (custom domain)
                                                      │
                                                      ▼
                                            MA Updater on device
```

- **`release`** signs the staged target-files with the MAOS key set and
  generates the factory image + full OTA zip (`script/generate-release.sh`
  in the AOSP tree).
- **`publish`** uploads the OTA zip first with an immutable cache header,
  then the `<device>-<channel>` metadata file with `no-store`, so a device
  polling mid-publish never sees metadata referencing a zip that isn't
  there yet. It also prepares/uploads the web-installer factory artifacts
  via `../installer/prepare-factory.sh`.
- **`ota.maproj.org`** is the R2 bucket `maos` exposed via a Cloudflare
  custom domain: an object keyed `<file>` is served at
  `https://ota.maproj.org/<file>`. Devices download straight from R2 — no
  GitHub Release and no server proxy are involved.
- The **MA Updater** app polls `https://ota.maproj.org/<device>-<channel>`
  (from `ro.maos.ota.server`; see `../updater/README.md`).

## Credentials (never commit)

The `publish` phase reads R2 credentials from the environment:

| Var | Meaning |
| --- | --- |
| `R2_ACCOUNT_ID` | Cloudflare account id (builds the R2 endpoint) |
| `R2_ACCESS_KEY_ID` | R2 API token access key id |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |

The bucket is fixed to `maos` in `build-maos.sh`. Create the API token in
the Cloudflare dashboard (R2 → Manage API Tokens) with **Object Read &
Write** on that bucket.

## Cloudflare setup (one-time)

1. Create the R2 bucket `maos`.
2. Attach the custom domain `ota.maproj.org` to it (R2 → Settings → Custom
   Domains). Cloudflare provisions TLS automatically.
3. Add a bucket CORS policy so the installer page (`ma.vayunmathur.com`)
   can fetch factory images (see `../docs/BUILD_RUNBOOK.md`).
4. Add a Cache Rule that bypasses cache for the channel-metadata files
   (paths not ending in `.zip`) so devices never see a stale build pointer.

See `../docs/BUILD_RUNBOOK.md` for the full build → sign → OTA → publish
sequence.
