# MAOS boot animation.
#
# The animation is the MAOS mouse glyph (the same mark as the maproj.org tab
# icon and the homepage card): it draws itself on over ~0.8s, holds, then
# loops a gentle fade until boot completes. White on black, 1080x1080@30fps.
#
# Source of truth is `generate.py` in this directory, which parses the SVG
# path with only the standard library + Pillow and emits the frames. The
# generated `bootanimation.zip` is checked in (reproducible, no build-time
# Python needed); rerun `./generate.py` after any artwork change and commit
# the new zip alongside it.
#
# Installed by `maos_branding.mk` via PRODUCT_COPY_FILES to
# `system/media/bootanimation.zip`, which the bootanimation service prefers
# over the AOSP default. The zip is STORED (uncompressed) — the loader mmaps
# it, and a deflated zip silently fails to play.
