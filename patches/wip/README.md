# Work-in-progress patches (NOT applied by build-maos.sh)

`apply_maos_patches()` in build-maos.sh iterates an explicit `repo:patchfile` list.
Nothing in this directory is on that list, so nothing here is applied automatically.

## cast-desktop-mode-*.patch

The cast desktop-mode framework work. **These bootloop the device** and are parked here
until the fault is found.

Established by bisection on shiba:

| tree state | result |
|---|---|
| all cast patches applied | bootloop (animation, then reset) |
| SystemUI cast patches reverted only | bootloop |
| SystemUI **and** framework cast patches reverted | **boots** |

So the fault is in the framework half — one of `DisplayManager.java`,
`VirtualDisplayConfig.java`, `DisplayDeviceInfo.java`, `LogicalDisplayMapper.java`,
`VirtualDisplayAdapter.java` — not SystemUI.

Two independent features are mixed together in that patch, and they can be re-applied
separately to narrow it further:

1. **Declared display modes** - `VirtualDisplayConfig.setSupportedModes()` plus
   `VirtualDisplayAdapter`'s `mDeclaredModes` / `modeForLocked()` /
   `setUserPreferredDisplayModeLocked()`. Lets the TV's real resolutions appear in
   Settings. Touches only virtual-display code paths.
2. **Connection-pending displays** - `VIRTUAL_DISPLAY_FLAG_CONNECTION_PENDING`,
   `DisplayDeviceInfo.FLAG_CONNECTION_PENDING`, and the `LogicalDisplayMapper` branch
   that starts such displays **disabled**. This is the one that touches
   `createNewLogicalDisplayLocked`, which runs for every display at boot including the
   built-in panel, so it is the stronger suspect.

Ruled out already: flag-bit collisions in all three flag namespaces,
`VirtualDisplayConfig` parcel symmetry (write and read orders match), and the
`virtual_displays_support_desktop_mode` aconfig flag (no aconfig storage file differs
between the booting and bootlooping images).
