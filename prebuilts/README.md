# prebuilts/

Modern Apps release APKs are copied here by `scripts/collect-apks.sh` before an AOSP
build. They are intentionally **git-ignored** (large binaries, reproducible from the
Modern-Apps repo).

Expected files (28, matching the APPS list in `build-maos.sh`):

```
web-release.apk    camera-release.apk    pdf-release.apk
contacts-release.apk    calculator-release.apk    clock-release.apk
files-release.apk    photos-release.apk    appstore-release.apk
keyboard-release.apk    speech-release.apk    calendar-release.apk
music-release.apk    communicate-release.apk    auto-release.apk
euicc-release.apk    backup-release.apk    networklocation-release.apk
findfamily-release.apk    share-release.apk    cast-release.apk
setupwizard-release.apk    logviewer-release.apk    updater-release.apk
parentalcontrols-release.apk    screentime-release.apk    health-release.apk
emergency-release.apk
```

Populate them with, e.g.:

```
scripts/collect-apks.sh /path/to/Modern-Apps
```
