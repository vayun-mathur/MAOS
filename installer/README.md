# MAOS web installer

A browser-based flasher at **`https://ma.vayunmathur.com/os/install`**, in the style of
GrapheneOS's `/install/web`. It talks fastboot to a connected Pixel over **WebUSB** and
flashes the MAOS factory image — no `adb`/`fastboot` tools or command line needed.

## Pieces

| Where | What |
| --- | --- |
| `location_share_server/os_installer/` | The static front-end: `install.html`, `install.css`, `installer.js` (wizard), `fastboot.js` (WebUSB fastboot client). Served at `/os/install` on `ma.vayunmathur.com`. |
| `MAOS/installer/prepare-factory.sh` | Build-host script: turns a release image into a `manifest.json` + per-partition images and uploads them to R2. For the **install zip** (preferred) it translates GrapheneOS's `script.txt` verbatim; for a legacy **factory zip** it builds a best-effort/`-P` plan and splits oversized images into sparse chunks. |
| `MAOS/installer/script_to_manifest.py` | Translates an install zip's `script.txt` (GrapheneOS's verified flash sequence) into ordered manifest steps. |
| `MAOS/installer/sparse_split.py` | Splits a raw image into multiple Android sparse images, each under the device's max-download-size (legacy factory-zip path only). |
| R2 (`ota.ma.vayunmathur.com/factory/<device>/…`) | Hosts the manifest + images; the browser streams them directly. |

## Flow

```
factory image ──prepare-factory.sh──▶ manifest.json + images ──▶ R2 (factory/<device>/latest/)
                                                                        │
   ma.vayunmathur.com/os/install  ◀── static app served by server      │
        │  (WebUSB fastboot)                                            │
        ▼                                                               ▼
     Pixel in bootloader mode  ◀────────── streams images from R2 ──────
```

The installer reads `factory/<device>/latest/manifest.json`, then for each step drives the
device over WebUSB — `check-var` / `check-requirements` (verify), `flash` (to the active or
inactive/"other" slot), `erase`, `run-cmd`, `toggle-active-slot` / `set-active`,
`snapshot-update-cancel`, `reboot-bootloader`, `reboot` — streaming each referenced image
straight from R2 and flashing it before fetching the next (so a multi-GB `super` never has
to fit in memory at once).

## Before you have any builds

You don't need to upload anything: if `factory/<device>/latest/manifest.json` is missing
(404), the installer detects the device, lets it connect/unlock, and shows **"No MAOS build
is available for &lt;device&gt; yet"** when the user clicks Download.

If you'd rather show an explicit message (e.g. a bucket-wide default), upload a stub
`manifest.json` with `available: false`:

```json
{
  "available": false,
  "message": "MAOS builds aren't available yet — check back soon."
}
```

Put it at `factory/<device>/latest/manifest.json` for a specific model. The installer treats
either a 404 or `available: false` as "no build yet" (a friendly notice, not an error).

## Publishing a build for the installer

```bash
# On the Linux build host, after producing a release (runbook step 8):
export R2_ACCESS_KEY_ID=...  R2_SECRET_ACCESS_KEY=...  R2_ACCOUNT_ID=...
installer/prepare-factory.sh -d cheetah -b "$BUILD" -f <device>-install-<build>.zip
```

This uploads to both `factory/<device>/<build>/` and `factory/<device>/latest/` (the
installer defaults to `latest`). `build-maos.sh`'s `publish` phase runs this for you with the
install zip.

### The flash plan

The correct, brick-safe flash sequence for a release is GrapheneOS's own — shipped as
`script.txt` inside the **install zip** (`<device>-install-<build>.zip`), alongside the whole
`super` already pre-split into `super_*.img`. When `prepare-factory.sh` sees a `script.txt`
it translates it verbatim (`script_to_manifest.py`) into ordered manifest steps and copies
the images as-is — no re-splitting, no invented plan. This is the default and what you should
use for a real release.

Supported step actions: `check-var`, `check-requirements`, `flash` (optional `slot:"other"`),
`erase`, `run-cmd`, `toggle-active-slot`, `set-active`, `snapshot-update-cancel`,
`reboot-bootloader`, `reboot`.

#### Legacy factory-zip fallback

If you only have a **factory zip** (no `script.txt`), `prepare-factory.sh` builds a
partition→image map and either follows an explicit `-P plan.json` or emits a **best-effort**
plan (and prints a warning). Oversized images (e.g. `super`) are split into sparse chunks
with `sparse_split.py`. Treat the auto plan as a scaffold — pass `-P` mirroring that device's
`flash-all` and validate on a device before publishing:

```bash
installer/prepare-factory.sh -d cheetah -b "$BUILD" -f factory.zip -P plan.json
```

`plan.json` is a JSON array of steps, e.g.:

```json
[
  {"action":"flash","partition":"bootloader","image":"bootloader-cheetah-*.img"},
  {"action":"reboot-bootloader"},
  {"action":"flash","partition":"radio","image":"radio-cheetah-*.img"},
  {"action":"reboot-bootloader"},
  {"action":"flash","partition":"boot","image":"boot.img"},
  {"action":"flash","partition":"init_boot","image":"init_boot.img"},
  {"action":"flash","partition":"dtbo","image":"dtbo.img"},
  {"action":"flash","partition":"vendor_boot","image":"vendor_boot.img"},
  {"action":"flash","partition":"vbmeta","image":"vbmeta.img"},
  {"action":"flash","partition":"super","image":"super.img"},
  {"action":"erase","partition":"userdata"},
  {"action":"reboot"}
]
```

`image` names an entry from the factory image (top-level or inside `image-*.zip`). Any image
over `-m` bytes (default 100 MiB, e.g. `super`) is auto-split into sparse chunks and expanded
into multiple flash steps to the same partition.

## Required: R2 CORS

The installer page is served from `ma.vayunmathur.com` but fetches the manifest + images
from `ota.ma.vayunmathur.com` (R2) — a cross-origin request. **The R2 bucket must send CORS
headers allowing `https://ma.vayunmathur.com`**, or the browser blocks the downloads. In the
R2 bucket settings, add a CORS policy like:

```json
[
  {
    "AllowedOrigins": ["https://ma.vayunmathur.com"],
    "AllowedMethods": ["GET"],
    "AllowedHeaders": ["range"],
    "ExposeHeaders": ["content-length", "content-range", "accept-ranges"],
    "MaxAgeSeconds": 3600
  }
]
```

## Browser support & safety

- **Chromium desktop only** (Chrome/Edge). WebUSB isn't in Firefox/Safari.
- Everything runs locally: images download from R2 to the browser and go to the device over
  USB. Nothing is uploaded.
- Re-locking the bootloader is offered only after a successful flash — locking over a bad
  image can hard-brick the device.

## Status / caveats

The fastboot client and prep scripts are authored against the documented fastboot + sparse
formats but have **not been validated end-to-end on a device** (that needs real hardware and
a real MAOS factory image). Expect to iterate on the per-device flash plan and, if a device's
`super` handling differs, on the sparse splitting. See the inline "verify on device" notes.
