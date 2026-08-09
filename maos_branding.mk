# MAOS branding — inherited from modern_apps.mk.
#
# You cannot ship as "GrapheneOS"; this rebrands the build as MAOS (Modern Apps OS).
# Full de-branding also requires overlaying the Settings "About phone" strings and
# swapping boot logos/wallpapers — those live under overlay/ and are called out in
# docs/BUILD_RUNBOOK.md. This file covers the build.prop-level identity.
#
# NOTE: changing brand/fingerprint means the build no longer matches GrapheneOS's
# attestation/OTA identity — expected for a fork. Because MAOS is self-signed, Play
# Integrity / stock attestation won't pass regardless; see the runbook.

PRODUCT_BRAND := MAOS
PRODUCT_MANUFACTURER := MAOS

# Marketing/version identity surfaced to our own apps (e.g. the Updater) and About.
# Keep MAOS_VERSION in sync with the OTA build number used by ota/build-ota.sh.
MAOS_VERSION ?= 1
MAOS_CHANNEL ?= stable

PRODUCT_PRODUCT_PROPERTIES += \
    ro.maos.version=$(MAOS_VERSION) \
    ro.maos.channel=$(MAOS_CHANNEL) \
    ro.maos.ota.server=https://ota.ma.vayunmathur.com

# Do NOT set ro.build.tags=test-keys — we sign with our own release keys, so this must
# remain release-keys (handled by the release signing step, not here).
