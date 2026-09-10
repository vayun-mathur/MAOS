# MAOS — Modern Apps OS

MAOS is a private, de-Googled Android OS for Pixel phones. It's derived from
[GrapheneOS](https://grapheneos.org) and replaces the stock system apps with the
first-party [Modern Apps](https://github.com/vayun-mathur) suite (`com.vayunmathur.*`) —
a clean, cohesive set of everyday apps built to work together.

## Install

Flash MAOS straight from your browser with the WebUSB installer:

**→ https://ma.vayunmathur.com/os/install**

You'll need a supported Pixel and a Chromium-based desktop browser (Chrome, Edge). No
command-line tools required. Once installed, MAOS keeps itself up to date automatically
over the air.

## What's included

MAOS ships Modern Apps in place of the stock apps, including a **Web** browser, **Camera**,
**Photos**, **PDF** viewer, **Files**, **Contacts**, **Calendar**, **Clock**, **Calculator**,
**Communicate** (calls + texts), **Music**, **Keyboard**, **Speech**, **App Store**, and
**Backup**. Everything else you expect from a GrapheneOS-based OS — the security and privacy
hardening, sandboxed Google Play compatibility, and per-app permissions — is still there.

## What the apps can do on MAOS

Because MAOS ships these apps as part of the OS, several of them do things a normal
app installed from an app store simply can't:

- **Cast** — cast to a TV in **desktop mode**, using the TV as a separate, extended screen
  rather than just mirroring your phone. You get a mirror-or-desktop chooser when you connect,
  it picks the TV's best resolution automatically, and it shows up directly in
  **Settings › Cast** (no need to open the app).
- **Find Family** — locate your phone even when it's **powered off** or the battery has died,
  and see its location before the phone is unlocked.
- **Files** — is the **system file picker**: whenever any app asks you to open or save a
  file, you browse with Files, with full access to your storage.
- **Communicate** — is your default **phone and text-messaging** app, handling calls and
  SMS/MMS.
- **eSIM** — set up and manage **eSIMs** natively, built into the OS.
- **Backup** — makes **encrypted backups** of your apps and data to a folder or your own
  cloud (WebDAV/Nextcloud), protected by a recovery phrase.
- **Speech** — provides **offline** voice typing (speech-to-text) and text-to-speech to
  every app on the device.
- **Keyboard** — is available on the **lock screen** and during first-time setup.

The remaining apps (Camera, Photos, PDF, Contacts, Calculator, Clock, Calendar, Music,
App Store, Web) are simply the built-in defaults — the same apps you'd get from the store.

## Building it yourself / technical details

This repository is the build overlay applied on top of GrapheneOS, not the OS source
itself. Build instructions, the full list of app swaps, signing, and OTA details are in
**[IMPLEMENTATION_README.md](IMPLEMENTATION_README.md)**.

---

_This is not the source code for the OS. This is a build script, which contains a collection
of patches which are then applied to GrapheneOS. You may view all relevant source code and
licenses [here](https://github.com/grapheneos)._
