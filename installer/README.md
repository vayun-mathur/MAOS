# MAOS web installer

A browser-based flasher at **`https://ma.vayunmathur.com/os/install`**, in the style of
GrapheneOS's `/install/web`. It talks fastboot to a connected Pixel over **WebUSB** and
flashes the MAOS factory image — no `adb`/`fastboot` tools or command line needed.

## Pieces

| Where | What |
| --- | --- |
| `location_share_server/os_installer/` | The static front-end: `install.html`, `install.css`, `installer.js` (wizard), `fastboot.js` (WebUSB fastboot client). Served at `/os/install` on `ma.vayunmathur.com`. |
| `MAOS/installer/prepare-factory.sh` | Build-host script: turns a factory image into a `manifest.json` + per-partition images (splitting oversized ones into sparse chunks) and uploads them to R2. |
| `MAOS/installer/sparse_split.py` | Splits a raw image into multiple Android sparse images, each under the device's max-download-size. |
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

The installer reads `factory/<device>/latest/manifest.json`, then for each step does
`flash` / `erase` / `reboot-bootloader` / `reboot` over WebUSB, streaming each referenced
image straight from R2.

## Publishing a build for the installer

```bash
# On the Linux build host, after producing a factory image (runbook step 8):
export R2_ACCESS_KEY_ID=...  R2_SECRET_ACCESS_KEY=...  R2_ACCOUNT_ID=...
installer/prepare-factory.sh -d shusky -b "$BUILD" -f <device>-factory-*.zip
```

This uploads to both `factory/<device>/<build>/` and `factory/<device>/latest/` (the
installer defaults to `latest`).

### The flash plan (READ THIS)

The exact partitions/slots/order for a real install are defined by the factory image's own
`flash-all.sh` and are device/release specific. `prepare-factory.sh` without `-P` generates
a **best-effort** plan and prints a warning — treat it as a scaffold, not a guarantee. For a
real release, pass an explicit plan mirroring that device's `flash-all`:

```bash
installer/prepare-factory.sh -d shusky -b "$BUILD" -f factory.zip -P plan.json
```

`plan.json` is a JSON array of steps, e.g.:

```json
[
  {"action":"flash","partition":"bootloader","image":"bootloader-shusky-*.img"},
  {"action":"reboot-bootloader"},
  {"action":"flash","partition":"radio","image":"radio-shusky-*.img"},
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

Supported step actions: `flash`, `erase`, `reboot-bootloader`, `reboot`, `set-active`.

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
