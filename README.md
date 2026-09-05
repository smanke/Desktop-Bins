# Desktop Bins

A macOS menu bar app that adds Stardock Fences–style containers to the desktop:
labeled, resizable regions that hold desktop icons, keep them arranged on a
grid, and carry them along when the region is moved.

## Features

- Draggable, resizable, titled bins drawn on the desktop
- Icons dropped inside snap to a configurable grid
- Moving a bin moves the icons it contains
- Optional gap-free packing (icons refill from the top-left, no holes)
- Collapse/expand a bin to just its title bar (double-click the title bar)
- Rename, recolor and delete via right-click or ⌘-click on the title bar
- Save / restore an icon layout per bin
- Grid spacing presets and settings in the menu bar
- Bins remember which physical monitor they belong to, and appear on the main
  display rather than vanishing when that monitor is absent
- "Bring All Bins to Main Display" rescues bins stranded on a monitor that is
  no longer attached
- Optional launch at login

## Installing

Download the `.dmg` from the [latest release](https://github.com/smanke/Desktop-Bins/releases),
open it, and drag the app onto Applications. The image and the app inside are
both notarized, so it opens without a Gatekeeper warning.

## Permissions

The app moves icons by asking Finder to do it over Apple Events, so it needs
**System Settings › Privacy & Security › Automation › Finder**. macOS raises
that prompt the first time the app sends a real Apple Event — approve it.

Without that permission the app still launches and draws its bins, but
nothing it asks Finder to do has any effect: icons won't snap to the grid or
follow a bin when it moves, and macOS reports no error. If bins look inert,
check this first.

## Building

```bash
./build_app.sh
cp -R ".build/app/Desktop Bins.app" /Applications/
open "/Applications/Desktop Bins.app"
```

Requires macOS 13+. The build produces a universal (arm64 + x86_64) bundle.

## Implementation notes

These were all non-obvious, and each one silently breaks the app if wrong.

### Desktop icon positions

Finder exposes desktop icon locations as the **`desktop position`** property.
The plain `position` property reports `-1,-1` for desktop items. Iterating
Finder item references (`repeat with x in (items of desktop)`) also fails —
read the parallel `name of every item` / `desktop position of every item`
lists and walk those instead.

Finder's desktop coordinates are top-left origin with y growing downward,
anchored at the primary display's top-left; AppKit is bottom-left origin with
y growing upward. Conversion is `finderY = primaryScreenHeight - appKitY`.

### Window layering

macOS offers no single window level that both draws behind desktop icons and
receives clicks, so each bin is three windows:

- a **backdrop** below Finder's icon layer (`desktopWindow + 1`) that ignores
  mouse events and draws the bin — this keeps the bin body live Finder
  desktop, so icons can be dragged in, out and around normally;
- two small **chrome** windows above the icon layer
  (`desktopIconWindow + 1`) for the title bar strip and resize corner, which
  would otherwise never see a click.

Because the chrome sits above the icon layer, it must accept dragged files
itself — otherwise a file dropped on the title bar is refused and springs
back to where it came from.

### Hardened runtime and Apple Events

The bundle is signed with `--options runtime`, which requires the
`com.apple.security.automation.apple-events` entitlement
(`Resources/DesktopBins.entitlements`). Without it the Apple Event is
blocked *before* TCC is consulted: no consent prompt appears, the app never
shows up under Automation in System Settings, and every Finder call fails
silently.

Equally, do not pre-flight the permission with
`AEDeterminePermissionToAutomateTarget` during launch — blocking the main
thread there suppresses the very prompt it is meant to raise. Just send a
real Apple Event once the run loop is running.

### Code signing

`build_app.sh` signs with a Developer ID Application identity, picking the
first one in the keychain (override with `CODESIGN_IDENTITY`). This matters
for more than distribution: TCC keys a permission to the app's *designated
requirement*, and a certificate-backed signature produces one built from the
bundle identifier and team, with no code hash in it:

```
identifier "com.smanke.DesktopBins" and anchor apple generic
  and certificate leaf[subject.OU] = "<team id>"
```

That requirement is identical across rebuilds, so the Finder Automation
grant survives them.

Ad-hoc signing (the fallback when no identity is found) has no stable
designated requirement — macOS identifies the app by a code hash that
changes on every rebuild, silently revoking Automation access each time. If
that happens, recover with:

```bash
tccutil reset AppleEvents com.smanke.DesktopBins
```

then relaunch and approve the prompt.

`./notarize.sh` notarizes and staples a build, and `./make_dmg.sh` packages
it into a signed, notarized `.dmg`. Both the app and the disk image need
their own ticket: a download picks up a quarantine attribute, and Gatekeeper
checks the image before it ever looks at the app inside.

### Other notes

- All Finder scripting is serialized on one queue; `NSAppleScript` is not
  thread safe.
- Icons follow a bin drag live, throttled to 50 ms with overlapping frames
  dropped, since each update is an Apple Event round trip. They will trail
  slightly at high drag speeds.

### Multiple displays

Each bin stores the **stable UUID** of the display it sits on
(`CGDisplayCreateUUIDFromDisplayID`) plus its position relative to that
display's origin, rather than an absolute screen point.

A raw `CGDirectDisplayID` is not usable for this: the system assigns those
per session, so the same monitor can return with a different id after being
unplugged. Storing the offset rather than an absolute point also means bins
stay where they belong when displays are rearranged and the global
coordinate space shifts underneath them.

A bin whose display is not attached is shown on the main display instead of
being hidden — plugging a laptop into a different set of monitors should not
look like the bins were lost. Its stored pin is deliberately left untouched
so it returns home when its own monitor comes back; it is only re-pinned if
the user actually moves it. Offsets from a larger monitor are clamped into
the fallback screen so a bin can't land off-screen.

Changing monitors also makes Finder reflow the desktop, scattering icons out
of their bins. Their saved coordinates are stale at that point — they refer
to the old layout — so members are re-laid out on each bin's current grid by
name rather than by replaying old positions. The app watches
`NSApplication.didChangeScreenParametersNotification`, coalescing the burst
of notifications and waiting for Finder to settle before reading positions
back.

Finder's desktop coordinate space spans all displays and is anchored at the
primary display's top-left, so the icon grid works on secondary displays
without any extra conversion.
