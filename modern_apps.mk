# MAOS (Modern Apps OS) — product configuration overlay.
#
# Inherited from the device product makefile. The MAOS app list itself lives in
# GrapheneOS's build/make/target/product/*.mk, patched in by phase_overlay - a
# makefile inherited from here cannot add or remove PRODUCT_PACKAGES entries that
# belong to the parent, because inherit-product defers resolution (see
# build/make/core/product.mk:539).
#
# -----------------------------------------------------------------------------------

# 1. App membership (which Modern Apps ship, which stock apps are dropped) is applied
#    by patches/platform_build.patch against build/make/target/product/*.mk. The
#    Android.bp modules referenced there are defined alongside this file.

# NOTE on the browser (Vanadium): Vanadium provides BOTH the default browser AND the
# system WebView provider. We make Modern Apps Web the default browser via the
# config_defaultBrowser overlay but deliberately KEEP Vanadium installed so WebView
# keeps working (our Web app uses androidx.webkit / system WebView). If you want to
# drop the Vanadium *browser* entirely, identify the browser-only module name in your
# tree and add it to the filter-out list above — do NOT remove the WebView/Trichrome
# modules.

# NOTE on speech: Modern Apps Speech REPLACES GrapheneOS's SpeechServices (which we remove
# above). It becomes the default on-device recognizer via config_default*SpeechRecognitionService
# (overlay) and, being the only remaining installed TTS engine, the default TTS engine. Its
# RECORD_AUDIO runtime permission must be granted by default for the recognizer to work
# headless — see the default-permissions grant referenced below.

# NOTE on the keyboard: Modern Apps Keyboard replaces AOSP LatinIME as the IME. For it to
# work on the lock screen after a reboot it must be Direct Boot aware; that attribute is set
# in the keyboard app's own manifest (Modern-Apps repo). With LatinIME removed it is the sole
# preinstalled IME, so the system enables/selects it by default.

# NOTE on communicate (dialer + messaging): Modern Apps Communicate (com.vayunmathur.communicate)
# is a single app that provides BOTH the phone dialer and the SMS/MMS messenger. It replaces the
# two separate GrapheneOS/AOSP UI apps Dialer (com.android.dialer) and Messaging
# (com.android.messaging), both removed above. It is made the default dialer via config_defaultDialer
# and the default SMS app via config_defaultSms in the frameworks/base overlay (RRO). Holding the
# DIALER and SMS roles causes the role system to auto-grant its runtime permissions, so it is NOT a
# priv-app and needs no default-permissions grant. Only the UI apps are removed; the telephony
# backends (TelephonyProvider, telecom framework) stay intact. Neither `Dialer` nor `Messaging` ends
# in `Provider`, so the safety guard above correctly permits removing them.

# NOTE on network location + geocoder: Modern Apps NetworkLocation (com.vayunmathur.networklocation)
# is a priv-app that provides BOTH the network location provider and the offline geocoder. It
# replaces GrapheneOS's NetworkLocation module (app.grapheneos.networklocation), which we remove
# above. Removing that module also drops its bundled privapp-permissions/sysconfig etc files (they
# are `required:` deps of the module). Our app is pinned via config_networkLocationProviderPackageName,
# config_geocoderProviderPackageName and config_locationProviderPackageNames in the frameworks/base
# overlay, gets its privileged perms from privapp-permissions-modern-apps.xml, and gets Doze /
# Data-Saver exemptions (for always-on background operation) from sysconfig-modern-apps.xml below.
# `NetworkLocation` is a provider *implementation* app, NOT a content-provider backend — it does not
# end in `Provider`, so the safety guard above correctly permits removing it.

# NOTE on eSIM (euicc): Modern Apps Euicc (com.vayunmathur.euicc) is a priv-app that is the system
# eSIM LPA (Local Profile Assistant). It declares android.service.euicc.EuiccService plus the eSIM
# management LUI (MANAGE_/PROVISION_EMBEDDED_SUBSCRIPTIONS) and implements the full SGP.22 stack,
# driving the eUICC over a telephony logical channel. It gets its signature|privileged perms
# (WRITE_EMBEDDED_SUBSCRIPTIONS / MODIFY_PHONE_STATE / READ_PRIVILEGED_PHONE_STATE) from
# privapp-permissions-modern-apps.xml. It replaces Google's LPA app EuiccGoogle
# (com.google.android.euicc) and its companion RRO EuiccGoogleOverlay (com.google.android.euiccoverlay),
# both removed above; with the Google LPA gone, ours is the sole app resolving the EuiccService intent
# with the privileged eSIM permission, so the framework selects it as the LPA automatically (no config
# pin needed). Only the LPA *app* layer is replaced: the proprietary Pixel hardware backend
# EuiccSupportPixel (com.google.euiccpixel) and the modem/Shannon firmware are KEPT — they provide the
# low-level access to the built-in eUICC that this app sits on top of. `EuiccGoogle`/`EuiccGoogleOverlay`
# are not content-provider backends (they don't end in `Provider`), so the safety guard permits removal.

# NOTE on backup: Modern Apps Backup (com.vayunmathur.backup) is a priv-app that is the system
# app-data backup transport. It declares android.app.backup.BackupTransport via a service with the
# android.backup.TRANSPORT_HOST intent-filter (gated by the system-only BIND_BACKUP_TRANSPORT
# permission) and also performs standalone encrypted file/media backup. It gets its
# signature|privileged perms (BACKUP to act as a transport, WRITE_SECURE_SETTINGS to activate
# itself) from privapp-permissions-modern-apps.xml, and is pinned as the default transport via
# config_backup_transport in the frameworks/base overlay (RRO). It replaces GrapheneOS's Seedvault
# (com.stevesoltys.seedvault, module Seedvault) and the GrapheneOS contacts backup transport
# (app.grapheneos.backup.contacts, module ContactsBackup), both removed above; with Seedvault gone,
# ours is the transport pinned by config_backup_transport. Backups are encrypted end-to-end with a
# BIP-39 recovery code, so there is no separate account/content-provider backend to keep. Neither
# `Seedvault` nor `ContactsBackup` ends in `Provider`, so the safety guard above permits removal.
# (Module names are the GrapheneOS build names — re-confirm on your synced tree if a build surprises
# you, per the note on the removal list above.)

# 3. framework-res config

# 3. framework-res config (default browser, documents UI, speech recognition service, and the
#    geocoder / network-location provider pins + their override bools) ships as an explicit
#    static, platform-signed RRO. With PRODUCT_ENFORCE_RRO_TARGETS := * (from generic_system.mk)
#    a plain PRODUCT_PACKAGE_OVERLAYS on framework-res is turned into an auto-generated product
#    RRO named framework-res__$(PRODUCT_NAME)__auto_generated_rro_product.apk, which collides
#    with the identically named prebuilt adevtool ships under vendor/google_devices/<dev>/overlays
#    (soong "packaging conflict"). An explicit module has a unique name and coexists with it.
#    platform signing is required to overlay the non-public config_* resources; isStatic makes it
#    always-on at boot. See vendor/modern-apps/rro/MaosFrameworkResRRO/.
PRODUCT_PACKAGES += MaosFrameworkResRRO

#    The overlay/ dir now only carries the GrapheneOS Updater OTA-URL overlay (no framework-res
#    overlay here, so no auto-generated framework-res RRO is produced).
PRODUCT_PACKAGE_OVERLAYS += vendor/modern-apps/overlay

# 3b. Default-permission grant so the Speech recognizer/TTS gets RECORD_AUDIO headlessly.
PRODUCT_COPY_FILES += \
    vendor/modern-apps/default-permissions-modern-apps.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/default-permissions/default-permissions-modern-apps.xml

# 4. Privileged-permission allowlist so Files (priv-app) may hold MANAGE_DOCUMENTS,
#    NetworkLocation (priv-app) may hold INSTALL_LOCATION_PROVIDER / LOCATION_HARDWARE /
#    MODIFY_PHONE_STATE / UPDATE_DEVICE_STATS, Euicc (priv-app, the eSIM LPA) may hold
#    WRITE_EMBEDDED_SUBSCRIPTIONS / MODIFY_PHONE_STATE / READ_PRIVILEGED_PHONE_STATE, and
#    Backup (priv-app, the app-data backup transport) may hold BACKUP / WRITE_SECURE_SETTINGS.
PRODUCT_COPY_FILES += \
    vendor/modern-apps/privapp-permissions-modern-apps.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/privapp-permissions-modern-apps.xml

# 4b. Sysconfig so NetworkLocation is exempt from Doze / Data Saver and keeps running in the
#     background (always-on), mirroring GrapheneOS's own networklocation sysconfig.
PRODUCT_COPY_FILES += \
    vendor/modern-apps/sysconfig-modern-apps.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/sysconfig/sysconfig-modern-apps.xml

# 5. MAOS branding (PRODUCT_* + ro.maos.* props). Kept separate for readability.
$(call inherit-product-if-exists, vendor/modern-apps/maos_branding.mk)

# 6. The old leak guard lived here. It filtered the same local PRODUCT_PACKAGES as the
#    removal above, so it was always empty and never fired - which is why a build that
#    shipped zero MAOS apps still reported success. Removal is now a patch, and a patch
#    that no longer applies fails loudly in phase_overlay.
