# prebuilts/

Modern Apps release APKs are copied here by `scripts/collect-apks.sh` before an AOSP
build. They are intentionally **git-ignored** (large binaries, reproducible from the
Modern-Apps repo).

Expected files:

```
web-release.apk        camera-release.apk      pdf-release.apk
contacts-release.apk   calculator-release.apk  clock-release.apk
files-release.apk      photos-release.apk      appstore-release.apk
```

Populate them with, e.g.:

```
scripts/collect-apks.sh /path/to/Modern-Apps
```
