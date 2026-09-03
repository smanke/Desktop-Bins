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
- Bins remember which physical monitor they belong to
- Optional launch at login

## Building

```bash
./build_app.sh
cp -R ".build/app/Desktop Bins.app" /Applications/
open "/Applications/Desktop Bins.app"
```

Requires macOS 13+. The build produces a universal (arm64 + x86_64) bundle.

## Permissions

The app moves icons by asking Finder to do it over Apple Events, so it needs
**System Settings › Privacy & Security › Automation › Finder**. macOS raises
that prompt the first time the app sends a real Apple Event.

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

### Known limitation: ad-hoc signing

The app is ad-hoc signed, so macOS identifies it by a code hash that changes
on **every rebuild**, which invalidates the Automation grant each time. When
that happens, Finder control fails silently; recover with:

```bash
tccutil reset AppleEvents com.smanke.DesktopBins
```

then relaunch and approve the prompt. Signing with a stable (self-signed)
certificate would make the grant persist across builds.

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

Bins whose display is not currently attached are kept in the store but
hidden, and reappear in place when that monitor is reconnected. The app
watches `NSApplication.didChangeScreenParametersNotification` to react to
monitors being attached, detached or rearranged.

Finder's desktop coordinate space spans all displays and is anchored at the
primary display's top-left, so the icon grid works on secondary displays
without any extra conversion.
