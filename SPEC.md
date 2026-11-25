# DrawBot — design spec

A macOS menu-bar app. The user picks an image, drags a rectangle anywhere on screen (any app,
including full-screen apps) to define the canvas, and DrawBot moves the real cursor with
synthetic mouse events to paint the image in whatever drawing app is under that rectangle — one
color at a time. Before each color it prompts the user to select that color in the drawing app,
then continues.

Swift Package (tools 5.9, Swift 5 language mode, macOS 13+). Built into `build/DrawBot.app`
by `scripts/build_app.sh`. Three modules:

| Module | Path | Owner | Contents |
|---|---|---|---|
| DrawBotCore | Sources/DrawBotCore | Agent A | Pure logic. CoreGraphics/ImageIO/Foundation only, no AppKit. Unit-tested. |
| DrawBotSystem | Sources/DrawBotSystem | Agent B | macOS system layer: CGEvent mouse posting, permissions, hotkeys, window inspection, app activation, drawing engine. |
| DrawBot (exe) | Sources/DrawBot | Agent C | AppKit + SwiftUI app: menu bar, control panel, selection overlay, color prompt, HUD, orchestration, bundle/build script, README. |

`Sources/DrawBotCore/Types.swift` is fixed shared vocabulary (owned by the lead). Every other
file in Core and System currently contains a **stub** with the exact public signatures and doc
comments — those signatures are the contract. Implement the bodies; you may ADD public API or
private helpers/files, but do not rename/remove/alter existing public signatures. If a contract
is genuinely wrong, say so in your final report instead of silently changing it.

## Coordinate systems (most common source of bugs — be exact)

* **CG global** (CGEvent, CGWindowList bounds, everything in Core and System): points, origin at
  the top-left of the primary display, y DOWN.
* **Cocoa global** (NSWindow frames, NSScreen.frame, NSEvent.mouseLocation): points, origin at the
  bottom-left of the primary display (`NSScreen.screens[0]`, NOT `NSScreen.main`), y UP.
* Conversion: `cgY = primaryHeight - cocoaY`; rect: `cg.origin.y = primaryHeight - (cocoa.origin.y + cocoa.height)`.
  Use `Geometry` for all conversions. Points (not pixels) everywhere; Retina is irrelevant to event
  coordinates.

## Pipeline

1. `ImageLoader.loadCGImage(url)` (orientation-correct).
2. Canvas rect (CG global) + pen size → `GridLayout(canvas:penSize:)` → `columns × rows` grid.
3. `ImageLoader.rasterize(image, width: columns, height: rows)` — aspect-fit, centerd,
   letterbox transparent.
4. `Quantizer.quantize(raster, options)` — k-means in Lab, ≤ maxColors, merge near-duplicates.
5. Skip set: palette indices the user doesn't want drawn (default: near-white colors, since the
   canvas is usually white). `ColorMath.order(q, by:)` gives drawing order (default light→dark,
   so darker detail lands on top of any brush bleed).
6. Per color: `StrokePlanner.strokes(for: idx, in: q, layout:)` → `[ScreenStroke]` (serpentine
   horizontal runs, one press-drag-release per run; single cells are dots).
7. `DrawingEngine.draw(strokes:clampRect: canvas …)`.

Preview before a canvas exists: use a layout of the image's aspect ratio at ~240 columns. Recompute
when canvas, pen size or color count change (off the main thread; coalesce rapid changes).

## Synthetic input (Agent B) — requirements

* Events: `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton: .left)` posted to
  `.cghidEventTap`, one shared `CGEventSource(stateID: .hidSystemState)`.
* Set `kCGMouseEventClickState = 1` on down AND up (prevents accidental double-click semantics
  between consecutive strokes). Set `kCGMouseEventPressure` 1.0 on down/drag, 0 on up. Set
  `kCGMouseEventDeltaX/Y` on drags/moves (integer deltas from the previous posted point).
* Stroke = `move(to: start)` → sleep moveDelay → `mouseDown(start)` → sleep downDelay →
  `drag` events every ≤ stepSize points along the segment, sleeping eventDelay after each, last
  one exactly at `end` → `mouseUp(end)` → sleep upDelay.
* Dot stroke (start == end): down at p, drag to p + (0.5, 0) and back to p (many apps ignore a
  down/up with no drag), up at p.
* Use a precise sleep (`mach_wait_until` or `nanosleep`); delays are 1–30 ms.
* Escape detection while drawing: poll `CGEventSource.keyState(.combinedSessionState, key: kVK_Escape)`
  in the worker loop (cheap), AND the app also registers Esc as a Carbon hotkey while drawing and calls
  `requestStop`. Either path must work alone.
* User-movement detection: after posting each event remember the expected point; before posting
  the next, read the actual cursor (`CGEvent(source: nil)?.location`); if it is > userMoveThreshold
  from expected → release button, finish `.paused(resumeIndex: current, "Mouse moved")`.
  Must not false-trigger from our own events (compare against the last point WE posted; allow
  rounding).
* NEVER leave the button down: every exit path (stop, pause, completion, permission loss)
  releases the button. `requestStop` / `requestPause` set atomic flags checked between events.
* Clamp every posted point into clampRect.
* If `Permissions.isAccessibilityTrusted` becomes false mid-draw, finish `.stopped`.

## Window / focus rules (Agent B provides tools, Agent C applies them)

* App runs with `NSApp.setActivationPolicy(.accessory)` (LSUIElement) so its windows can appear
  over other apps' full-screen spaces. All DrawBot windows/panels use
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` and a high level
  (`.floating` for panels, `.screenSaver` for the selection overlay).
* The color prompt and the drawing HUD are **non-activating** `NSPanel`s
  (`.nonactivatingPanel`), so clicking "Continue" does not steal focus from the drawing app.
* While drawing, **no DrawBot window may overlap the canvas** (it would receive the clicks). The
  prompt is ordered out; the HUD is `ignoresMouseEvents = true` and placed outside the canvas
  (corner of the canvas's screen furthest from the canvas; if the canvas covers the screen, put it
  at the top-right corner anyway — it is click-through).
* Target app = `WindowInspector.targetApp(for: canvas)` captured right after the canvas is
  selected (after the overlay is closed and ~150 ms later).
* Before each color pass: (1) order out prompt; (2) `AppActivator.activate(target)`; (3) wait
  250 ms; (4) `WindowInspector.obstructions(of: canvas, targetPID:)` — if non-empty, show a warning
  in the prompt naming the app(s) ("Something from Preview is covering the canvas — move it
  away") with buttons "Check again" and "Draw anyway"; (5) countdown (configurable, default 1 s)
  shown on HUD; (6) draw.
* If DrawBot itself is the target (the built-in Test Canvas window) skip activation and skip
  self-obstruction checks.

## App behavior (Agent C)

Menu bar item (SF Symbol `paintbrush.pointed` / fallback `paintbrush`) with menu:
Show DrawBot (⌃⌥⌘P) · Select Canvas… (⌃⌥⌘S) · Start/Continue (⌃⌥⌘↩) · Stop (Esc while
drawing, ⌃⌥⌘.) · Open Test Canvas · Permissions… · Quit. Global hotkeys via `HotKeyCenter`.

**Control panel** (floating NSPanel, normal activating, SwiftUI content, ~420×640, resizable):
* Accessibility status row: green "Ready" or orange "DrawBot needs Accessibility permission"
  with "Grant…" (requestAccessibility + openAccessibilitySettings) — re-checked every 1 s while
  the panel is visible. Note: after granting, macOS sometimes requires relaunch; show a
  "Relaunch DrawBot" button when still untrusted after the user returns.
* Image: "Choose Image…" (NSOpenPanel, image UTTypes) + drag-and-drop + paste (⌘V) of an image;
  shows file name and pixel size.
* Canvas: "Select Canvas (⌃⌥⌘S)" + readout "640 × 480 pt at (x, y) on <screen name>"; target
  app name.
* Settings (persisted in UserDefaults): Colors (stepper/slider 1–32, default 8); Merge
  similar colors (ΔE slider 0–30, default 6); Pen size in points (1–40, default 4, plus helper
  text "Set your brush to ≈ N px (≈ 2N px on a Retina display at 100% zoom)" using the canvas
  screen's backingScaleFactor); Speed preset (picker) ; Color order (picker); Countdown seconds
  (0–5, default 1); "Pause if I move the mouse" (default on); "Skip near-white colors"
  (default on).
* Preview: quantized image (nearest-neighbor scaled, checkerboard where transparent) and a
  palette strip — each swatch shows the color, hex, % of area; click a swatch to toggle skip
  (skipped swatches crossed out). Footer: "N colors · M strokes · ≈ estimated time".
* "Start Drawing" button (disabled until image + canvas + permission).

**Canvas selection overlay**: one borderless transparent window per NSScreen, level
`.screenSaver`, behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, view
`acceptsFirstMouse = true`, crosshair cursor, light dim (black 15%) except the selected rect
(clear with a 1 px white + 1 px black outline), live size label. Instruction text centerd:
"Drag to select the drawing area · Esc to cancel". Drag constrained to the screen where it
began. Esc cancels (needs key window: `NSApp.activate(ignoringOtherApps: true)` + `makeKey`).
Rect < 8×8 pt is ignored (keep overlay up). On mouse-up: close all overlay windows, convert to CG
global with Geometry, store, then capture target app.

**Color prompt** (non-activating floating NSPanel, placed on the canvas's screen off the canvas
if possible): big swatch, "Color 2 of 6", hex (with "Copy hex" button that copies without '#'
— also copies on show if "auto-copy hex" setting on, default on), RGB, HSB, approximate name,
"≈ N strokes". Text: "Select this color in your drawing app, then press Continue (⌃⌥⌘↩)".
Buttons: Continue (default), Skip this color, Stop. When paused (mouse moved), the same panel
shows "Paused — <reason>" with Resume / Skip rest of this color / Stop. When finished: "Done!"
with Close.

**HUD** while drawing: small non-activating click-through panel: "Drawing color 2/6 ·
43% · Esc to stop", swatch. Also shows the countdown.

**Test Canvas**: a normal window (800×600) with a white NSView that records drags as lines
(width = pen size, current color = the color DrawBot is currently drawing, black otherwise), a
Clear button. `acceptsFirstMouse = true`. Lets the user verify DrawBot without a paint app.

**State machine** (AppController, main thread): idle → selectingCanvas → ready → awaitingColor(i)
→ drawing(i) → [paused(i, resumeIndex) → drawing(i)] → … → finished. Stop from any state returns
to ready with all panels/HUD cleaned up and hotkey Esc unregistered.

## Build (Agent C)

`scripts/build_app.sh`: `swift build -c release`, assemble `build/DrawBot.app`
(Contents/MacOS/DrawBot, Contents/Info.plist with CFBundleIdentifier `local.drawbot.DrawBot`,
LSUIElement true, LSMinimumSystemVersion 13.0, NSHighResolutionCapable, CFBundleShortVersionString
1.0), sign with the first "Apple Development" identity from `security find-identity -v -p codesigning`
if present (stable TCC identity across rebuilds), else ad-hoc `codesign --force -s -`. Print the path.
