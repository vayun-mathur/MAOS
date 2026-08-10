# MAOS (Modern Apps OS) — product configuration overlay.
#
# Include this from your device product makefile AFTER the base GrapheneOS/AOSP
# product has been inherited, so the $(filter-out ...) below can see and remove the
# stock app modules. Example (in device/.../aosp_<device>.mk):
#
#     $(call inherit-product, vendor/modern-apps/modern_apps.mk)   # must be LAST
#
# -----------------------------------------------------------------------------------

# 1. Add the Modern Apps prebuilts (defined in Android.bp).
PRODUCT_PACKAGES += \
    ModernAppsWeb \
    ModernAppsCamera \
    ModernAppsPdf \
    ModernAppsContacts \
    ModernAppsCalculator \
    ModernAppsClock \
    ModernAppsFiles \
    ModernAppsPhotos \
    ModernAppsStore \
    ModernAppsKeyboard \
    ModernAppsSpeech \
    ModernAppsCalendar \
    ModernAppsMusic \
    ModernAppsNetworkLocation

# 2. Remove the stock userspace apps we're replacing.
#    IMPORTANT: only ever remove *UI apps*, never content-provider backends. Contacts and
#    Calendar are each split in AOSP/GrapheneOS:
#      - UI:       Contacts (com.android.contacts), Calendar (com.android.calendar)
#      - backend:  ContactsProvider (com.android.providers.contacts),
#                  CalendarProvider (com.android.providers.calendar)
#    The *Provider modules implement ContactsContract/CalendarContract that our apps (and
#    everything else) depend on — removing them breaks the whole system. So we remove only
#    the UI apps, leaving ContactsProvider/CalendarProvider intact.
#
#    Module names below are VERIFIED against a real GrapheneOS device (Pixel 9 Pro XL, from
#    the /product/app/<Module>/<Module>.apk install paths). They should match cheetah (same
#    OS build across Pixels), but re-confirm on your synced tree if a build surprises you.
_maos_remove := \
    Camera \
    PdfViewerGOS \
    AppStore \
    Contacts \
    Calendar \
    DeskClock \
    ExactCalculator \
    Gallery2 \
    DocumentsUI \
    LatinIME \
    SpeechServices \
    Music \
    InfoApp \
    Auditor \
    NetworkLocation

# Safety: refuse to remove any content-provider backend. This makes the Contacts/Calendar
# footgun structurally impossible — if a *Provider ever ends up in the list, fail loudly.
_maos_providers := $(filter %Provider,$(_maos_remove))
ifneq ($(_maos_providers),)
$(error MAOS: refusing to remove content providers: $(_maos_providers). Remove only UI apps, never *Provider backends.)
endif

PRODUCT_PACKAGES := $(filter-out $(_maos_remove),$(PRODUCT_PACKAGES))

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

# 4. Privileged-permission allowlist so Files (priv-app) may hold MANAGE_DOCUMENTS, and
#    NetworkLocation (priv-app) may hold INSTALL_LOCATION_PROVIDER / LOCATION_HARDWARE /
#    MODIFY_PHONE_STATE / UPDATE_DEVICE_STATS.
PRODUCT_COPY_FILES += \
    vendor/modern-apps/privapp-permissions-modern-apps.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/privapp-permissions-modern-apps.xml

# 4b. Sysconfig so NetworkLocation is exempt from Doze / Data Saver and keeps running in the
#     background (always-on), mirroring GrapheneOS's own networklocation sysconfig.
PRODUCT_COPY_FILES += \
    vendor/modern-apps/sysconfig-modern-apps.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/sysconfig/sysconfig-modern-apps.xml

# 5. MAOS branding (PRODUCT_* + ro.maos.* props). Kept separate for readability.
$(call inherit-product-if-exists, vendor/modern-apps/maos_branding.mk)

# 6. Build-time guard: fail the build if any stock app we meant to drop is still in
#    PRODUCT_PACKAGES (catches upstream module renames that would silently re-add it).
_maos_leaked := $(filter $(_maos_remove),$(PRODUCT_PACKAGES))
ifneq ($(_maos_leaked),)
$(error MAOS: stock apps still present in PRODUCT_PACKAGES: $(_maos_leaked). Update the _maos_remove list in vendor/modern-apps/modern_apps.mk)
endif
