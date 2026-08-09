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
    ModernAppsStore

# 2. Remove the stock userspace apps we're replacing.
#    There is no PRODUCT_PACKAGES -= operator, so we filter them out. This only works
#    if this file is evaluated LAST (see header). Confirm the exact module names in your
#    synced tree — they occasionally change between GrapheneOS releases:
#      grep -rn --include=*.mk -e 'Camera' -e 'PdfViewer' -e 'DocumentsUI' ...
PRODUCT_PACKAGES := $(filter-out \
    Camera \
    PdfViewer \
    Apps \
    Contacts \
    DeskClock \
    Calculator \
    Gallery2 \
    DocumentsUI, \
    $(PRODUCT_PACKAGES))

# NOTE on the browser (Vanadium): Vanadium provides BOTH the default browser AND the
# system WebView provider. We make Modern Apps Web the default browser via the
# config_defaultBrowser overlay but deliberately KEEP Vanadium installed so WebView
# keeps working (our Web app uses androidx.webkit / system WebView). If you want to
# drop the Vanadium *browser* entirely, identify the browser-only module name in your
# tree and add it to the filter-out list above — do NOT remove the WebView/Trichrome
# modules.

# 3. Static resource overlays: config_defaultBrowser, config_documentsUiPackage,
#    WebView allowlist, branding.
PRODUCT_PACKAGE_OVERLAYS += vendor/modern-apps/overlay

# 4. Privileged-permission allowlist so Files (priv-app) may hold MANAGE_DOCUMENTS.
PRODUCT_COPY_FILES += \
    vendor/modern-apps/privapp-permissions-modern-apps.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/privapp-permissions-modern-apps.xml

# 5. MAOS branding (PRODUCT_* + ro.maos.* props). Kept separate for readability.
$(call inherit-product-if-exists, vendor/modern-apps/maos_branding.mk)

# 6. Build-time guard: fail the build if any stock app we meant to drop is still in
#    PRODUCT_PACKAGES (catches upstream module renames that would silently re-add it).
_maos_leaked := $(filter Camera PdfViewer Apps Contacts DeskClock Calculator Gallery2 DocumentsUI,$(PRODUCT_PACKAGES))
ifneq ($(_maos_leaked),)
$(error MAOS: stock apps still present in PRODUCT_PACKAGES: $(_maos_leaked). Update the filter-out list in vendor/modern-apps/modern_apps.mk)
endif
