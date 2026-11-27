# DrawBot

DrawBot is a small macOS menu-bar app that paints a picture for you, in any drawing app, by
moving the real mouse cursor.

There is also a Windows port in [`windows/`](windows/README.md), built from the same design with the
same features.

There's no plugin and no file import. You choose an image, drag a rectangle over the canvas of
whatever you're drawing in (Photoshop, Krita, Affinity, Pixelmator, a browser paint app, even
Preview's markup tools), and DrawBot draws the image there one color at a time. To the drawing
app it looks like someone with a very steady hand is scribbling very fast.

The catch with "any app" is colors. DrawBot can't reach into Krita's settings to change the
brush color, so by default it stops before each color and asks you to pick it. **Color
Learn** removes that step: you show DrawBot how your app's color picker works by selecting two
colors while it watches. From then on it selects every color itself.

> DrawBot drives your actual mouse. While it's drawing, keep your hands off the mouse and
> trackpad. If you move the mouse it pauses, and Esc stops it.

---

## Contents

- [How it works](#how-it-works)
- [Building](#building)
- [Granting Accessibility (and the ad-hoc signing trap)](#granting-accessibility-and-the-ad-hoc-signing-trap)
- [Drawing your first picture](#drawing-your-first-picture)
- [Color Learn](#color-learn)
- [Getting good results](#getting-good-results)
- [Hotkeys](#hotkeys)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Running the tests](#running-the-tests)
- [Known limitations](#known-limitations)

---

## How it works

1. **The canvas becomes a grid.** The rectangle you drag becomes a grid of cells. Each cell is
   the pen size you choose (4 pt by default), so a 400 × 300 pt canvas at 4 pt is a
   100 × 75 grid.
2. **The image is fitted to the grid.** The image is shrunk to that grid, centered, with its
   aspect ratio kept.
3. **Colors are reduced.** A k-means clustering in CIELAB space (perceptually even, so "close"
   means "looks close") brings the image down to a handful of colors, 8 by default. Colors
   that end up nearly identical are merged.
4. **Each color becomes strokes.** By default (**A\* paths**), DrawBot paints a row of a
   color's cells, then looks for the nearest cells of that color it hasn't painted yet, and
   uses the A\* search algorithm to find the shortest way there that only crosses cells of
   that same color. If that way is short, the pen stays down and goes there; if not, it lifts.
   So a solid shape becomes one zigzag stroke instead of one stroke per row, and the pen
   steers around other colors instead of lifting at each one. Each corner is held for one
   screen frame, so the drawing app doesn't cut it short and paint a neighboring cell. With
   **Top to bottom**, each row's stretch of same-colored cells is its own stroke, row by row.
   Either way a lone cell becomes a dot.

   In tests in PaintZ, both styles painted 99.5–100% of the cells at every speed.
   A\* paths needed 1 stroke instead of 20 for a solid blob, and 8 instead of 95 for thin
   lines; at Normal speed the thin lines took 2.1 s instead of 6.2 s.
5. **The strokes are drawn.** DrawBot posts synthetic mouse events, the same kind macOS
   accessibility tools use, along every stroke at a speed you choose. Before each color it
   brings the drawing app to the front and checks that no window covers the canvas. A window
   that is still there gets 2.5 seconds to go away (a color picker that was just used is often
   still closing) before DrawBot says something is in the way.

By default the light colors go down first and the dark ones last, so dark details end up on
top and hide any bleed from the lighter strokes.

## Building

You need macOS 13 or later and Xcode (or just the Swift toolchain) 5.9 or later.

```sh
./scripts/build_app.sh
open build/DrawBot.app
```

The script runs `swift build -c release`, assembles `build/DrawBot.app`, and signs it. It works
from any directory and only writes inside the project folder. Two optional environment
variables: `DRAWBOT_CONFIG=debug` for a debug build, and `DRAWBOT_SCRATCH=<dir>` to use a
different SwiftPM scratch directory.

How the app gets signed matters more than you'd expect:

- **If your keychain has an "Apple Development" certificate**, the script signs with it.
  macOS then recognizes each rebuild as the same app, and the Accessibility permission
  survives rebuilds.
- **Otherwise the app is signed ad-hoc.** That works fine, but every rebuild looks like a
  brand-new app to macOS. See the next section before you rebuild.

## Granting Accessibility (and the ad-hoc signing trap)

macOS only lets an app post mouse and keyboard events once you've given it Accessibility
access. Without it, the events are silently thrown away. Nothing errors; nothing happens.

1. Open DrawBot. A paintbrush icon appears in the menu bar and the control panel opens.
2. Click **Grant…** in the orange row. macOS shows its prompt and opens
   **System Settings → Privacy & Security → Accessibility**.
3. Turn on **DrawBot**. If it isn't listed, click **+** and choose `build/DrawBot.app`.
4. The row in DrawBot's panel turns green. If it doesn't, click **Relaunch DrawBot**, because
   macOS sometimes only applies the change after a restart.

**The trap.** An ad-hoc signed app is identified by a fingerprint of its exact binary, and
every rebuild changes that fingerprint. The Accessibility list keeps one row per app ID, and
that row remembers the fingerprint of the build you first approved. So after a rebuild the
switch can be on and DrawBot still has no permission. Flipping the switch doesn't help, and
neither does adding the new build with **+**: it lands on the same row and keeps the old
fingerprint.

What fixes it is deleting the row and granting again. Select DrawBot in the list, click **–**,
then add `build/DrawBot.app` with **+** (or click **Grant…** in DrawBot) and relaunch. From
Terminal, `tccutil reset Accessibility local.drawbot.DrawBot` does the same thing. To stop it
happening at all, sign with a stable certificate: a free Apple Development certificate from
Xcode works.

## Drawing your first picture

1. **Open your drawing app** with a blank white canvas at 100% zoom.
2. **Choose an image** in DrawBot's panel. You can click *Choose Image…*, drop a file onto the
   panel, or paste one with ⌘V.
3. **Select the canvas** with *Select Canvas* or ⌃⌥⌘S. The screen dims. Drag a rectangle over
   the part of the canvas you want painted, then let go (Esc cancels). The panel shows the
   rectangle's size and which app will receive the drawing.
4. **Tune it** while watching the preview:
   - **Colors**: how many colors (1–32). Fewer means faster, and fewer color changes.
     **1 makes a doodle**: the picture is split into a dark half and a light half, the light
     half is treated as blank canvas and skipped, and only the dark half is drawn, like a
     black pen on white paper. (The same happens when Color Learn learned an app with just
     one preset color.)
   - **Merge similar**: colors closer together than this are merged into one. *Off* keeps
     every color apart; around 10 merges shades that are hard to tell apart. (The number is
     the CIE ΔE color difference.)
   - **Pen size**: the grid spacing in points. *Set your brush to the size shown under the
     slider*; on a Retina screen many apps want twice that number in pixels.
   - **Speed**: how fast DrawBot moves. Every speed draws the whole picture; *Careful* is only
     worth it for apps that lag badly.
   - The time estimate under the preview covers everything: the strokes, the countdowns, and,
     when Color Learn selects the colors, each selection at the chosen speed. When you select
     colors yourself, it says "+ your color picks".
   - **Color selection**: how quickly DrawBot selects each color when Color Learn selects
     colors for you. *Normal* waits until nothing has been clicked for 1.5 s, then replays
     your picker input at the pace you used when teaching it. *Fast* and *Ludicrous* cut those
     pauses to a half and a quarter, and skip the countdown after the first color; on a
     drawing with many colors that saves several seconds per color. *Slow* is for apps that
     need longer to open their picker. If colors come out wrong at a fast setting, the app
     needs more time: go one step slower.
   - **Strokes**: *A\* paths* (the default, usually faster) or *Top to bottom*. See
     [How it works](#how-it-works).
   - **Color order**, **Countdown**, **Pause if I move the mouse**, and **Skip near-white
     colors**.
   - Click a swatch in the palette strip to skip that color, or click it again to include it.
5. **Click Start Drawing.** For each color, DrawBot shows the color with its hex, RGB and
   HSB values, and a **Copy hex** button. Select it in your app, then click
   **Continue** or press ⌃⌥⌘↩. After a short countdown it draws, with a small progress display
   in a corner of the screen.
6. When every color is done, you get **Done!** and a summary.

No paint app handy? **Test Canvas** (in the panel or the menu) opens a blank DrawBot window you
can draw into. It even has its own little color picker, so you can try Color Learn too.

## Color Learn

This is the part that makes DrawBot hands-free. Turn it on with **Color selection → Select
colors automatically (Color Learn)** and teach it once per app.

### Teaching it

1. Select the canvas first. DrawBot learns the color picker of the app under the canvas and
   remembers it for that app. In a web browser it remembers one picker **per website**, so Sumo
   Paint and PaintZ in the same browser each keep their own. The panel shows which site it sees
   ("Drawing into: Zen — paintz.app"). It reads the page's address through the Accessibility
   permission it already has, or the window title if the browser doesn't expose the address.
2. Click **Learn Color Picker…**.
3. DrawBot asks for an orange (#E68A2E). Select it in your app however you normally would, then
   press **Done** (⌃⌥⌘↩). While the prompt is up DrawBot records your clicks, drags, double
   clicks, typing and pastes. It ignores anything you do in DrawBot's own panels.
   **If your color picker is a popup or a dialog, open it, choose the color, and close it
   again before pressing Done, every time.** See [pickers that cover the canvas](#pickers-that-cover-the-canvas).
4. It asks for a dull slate blue (#4B5F73). The two colors are deliberately chosen to sit far
   apart on any kind of picker: opposite hues, different saturation and brightness, and every
   RGB channel different. Select it the same way and press **Done**.
5. DrawBot then selects a third color, a green, **by itself**, and asks whether it worked. Say
   **Yes**, and you're done. Say **No**, and it asks you to select that green yourself, adds
   it as a third example, and tries again with a new color.

### What it figures out

DrawBot compares your demonstrations step by step:

- **Anything that landed on the same spot both times is a fixed click**: opening the picker,
  focusing a field, pressing OK. It replays those as they are, double clicks included.
- **Anything you typed or pasted** is split into numbers and hex codes and checked against the
  requested color's hex, RGB, HSB and HSL values, at several scales (0–255, 0–100, 0–1, and
  the 0–240 that Windows-style pickers use). If you typed `#e68a2e` the first time and
  `#4b5f73` the second, DrawBot concludes "this is the hex code, lowercase, with a #". For any
  new color it types exactly what you typed (⌘A, Tab, Return and all), with the new value.
  A hex code you pasted (say, from **Copy hex**) counts as typed: DrawBot types the new value
  itself, so it never touches your clipboard or fills up your clipboard history.
- **Anything that moved is a color control.** DrawBot considers every way of explaining the
  moving clicks with one color model (HSB, HSL or RGB). A control could be a slider, a 2-D
  square, a color wheel, or a hue ring. It fits each explanation to your clicks and scores it:
  does it fit, is it a plausible size and on the screen, do the parts agree with each other (a
  hue strip is usually as tall as the square next to it), and how common is that layout. The
  winner is what it uses.

Two demonstrations can't always tell a color wheel from a square: two points fit either one
perfectly. That's what the test color and the **No** button are for. A third example rules
out the wrong shapes, because they can't fit three points.

When DrawBot replays a click-learned picker, it never presses right at the edge of a control.
Its idea of where the edges are comes from your (slightly imprecise) clicks, and can be a few
points off. So for colors near an edge (black, white, pure red) it presses safely inside the
square or slider and drags out to the edge. The picker clamps the drag, so the color comes out
exact instead of the press landing on the hue ring next door.

### Pickers that cover the canvas

Lots of pickers pop up on top of the drawing area: web apps like Sumo Paint, floating dialogs,
popovers. DrawBot handles them, with one rule: **every demonstration has to start with the
picker closed and end with it closed again.** DrawBot checks for other apps' windows covering
the canvas before it draws, but it can't see a popup inside the drawing app's own window. A
picker left open would get painted on.

DrawBot spots the two common slips and tells you what happened instead of learning something
broken:

- You opened the picker for the first color and left it open, so the second demonstration
  never opened it.
- The picker was still open when you pressed Done.

Clicks on the canvas count as picker clicks when they set the color, or when they hit the same
spot every time (an OK button, say). Drags and stray dabs on the canvas that don't change the
color are treated as test strokes and never replayed. Still, it's cleaner not to paint while
teaching.

### Tips for teaching

- **Type the hex code if your picker has a hex field.** It's the most reliable way, and colors
  come out exact. Clicking works too, but a click-learned picker is only as precise as the
  picker's pixels, so colors can be off by a little.
- Select both colors **the same way**: same controls, same order.
- When clicking, get as close as you can to the requested color. It doesn't have to be
  perfect.
- Leave the color picker **where it is** afterwards. DrawBot remembers screen positions, so
  if the picker moves, use **Learn Again…**.
- Watching the keyboard needs full Accessibility access. Without it DrawBot can only learn
  clicks, and the panel tells you so.

### Apps with preset color buttons

Some apps don't have a color picker at all, just a few preset color buttons (PaintZ's toolbar
palette, many kids' and pixel-art apps). DrawBot can learn those too:

1. Start the lesson as usual, then click **Preset colors…** in DrawBot's prompt.
2. Click **every color button once**, near its middle, about a second apart, then press
   **Done**.
3. DrawBot takes a screenshot of the app when this part of the lesson starts, before you click
   anything, and reads each button's color from the exact spot you clicked. It reads a small
   square around that spot and goes by the color that fills most of it, so a check mark, a
   selection ring or the button's edge doesn't throw it off. If the spot wasn't one clear color
   in that first screenshot, it uses the screenshot taken just before your click.
4. The colors it found are shown at the end. If one looks wrong, start over and click nearer
   the middle of that button.

When drawing, DrawBot first moves the picture's colors to the closest preset colors (similar
colors merge), so the preview shows exactly what will be painted. Then it clicks the right
button before each color.

This needs the **Screen Recording** permission (System Settings → Privacy & Security → Screen &
System Audio Recording) and macOS 14 or later. DrawBot asks for it the first time; macOS
usually wants DrawBot relaunched after you turn it on. DrawBot only looks at the drawing app's
window, and only during the lesson. Like Accessibility, an ad-hoc signed rebuild
loses this permission even though the switch still looks on: remove DrawBot's row with –, add it
again, and relaunch. If macOS refuses a screenshot, DrawBot stops the lesson and says so,
rather than letting the system's Screen Recording window pop up on every click.

### Using it

With Color Learn on, **Start Drawing** runs straight through: select color, draw, next color.
If a selection is interrupted (you moved the mouse, pressed Esc, or DrawBot couldn't bring
your app to the front), it falls back to the normal prompt for that color. That prompt has a
**Select for me** button to try again.

## Getting good results

- **Brush**: hard, round, 100% opacity, the size DrawBot shows. Turn off smoothing,
  stabilisers, "lazy mouse", and pressure or velocity dynamics, because they all fight
  straight lines.
- **Zoom 100%.** The pen size is in screen points; a zoomed canvas needs a scaled brush.
- **Retina screens**: many apps measure brushes in image pixels, which is about twice the point
  size at 100% zoom. The panel shows both.
- **Every speed draws completely.** Apps, browsers especially, handle input once per screen
  refresh. A stroke whose mouse button is released in the same refresh as its last movement is
  often never drawn at all, which used to leave gaps and missing dots, worse at higher speeds.
  DrawBot now waits a little over one refresh of the canvas's screen before releasing each
  stroke (about 10 ms at 120 Hz, 19 ms at 60 Hz). In tests, every speed covered 100% of solid
  and noisy patches; faster speeds are still faster, just not lossy.
- **Brush size**: if you still see thin white seams between rows, the brush in your app is
  smaller than DrawBot's pen size. Make it match (or 1 px bigger).
- **Hot corners**: turn them off, or keep the canvas away from screen corners.
- Keep palettes and floating windows off the canvas. DrawBot checks before every color and
  tells you who's in the way.
- Leave **Skip near-white** on for white paper. Painting white on white only costs time.

## Hotkeys

| Keys | What it does |
|---|---|
| ⌃⌥⌘P | Show the DrawBot panel (while drawing, it pauses first) |
| ⌃⌥⌘S | Select the canvas |
| ⌃⌥⌘↩ | Continue / Resume / Done (whenever DrawBot is waiting for you) |
| ⌃⌥⌘. | Stop |
| Esc | Stop while drawing; cancel a countdown, a canvas selection or an automatic color selection |
| ⌘Q | Quit DrawBot (when one of its windows is in front) |

DrawBot only claims Esc while it's actually busy, so Esc works normally in your apps the rest
of the time. To quit while another app is in front, use **Quit DrawBot** in the paintbrush
menu. Closing the panel only hides it, because DrawBot keeps running in the menu bar so its
hotkeys work.

## Troubleshooting

- **Nothing happens, or "macOS ignored DrawBot's mouse events".** The Accessibility entry is
  stale; see [the ad-hoc signing trap](#granting-accessibility-and-the-ad-hoc-signing-trap).
  Remove the row with **–**, grant it again, and relaunch.
- **"Something from <App> is covering the canvas."** DrawBot already waited 2.5 seconds for it
  to go away, so it is really there. Move that window or palette away and click
  *Check again*, or *Draw anyway* if you know better.
- **Strokes land in the wrong place.** The canvas moved or scrolled after you selected it, or
  the zoom changed. Select the canvas again.
- **Gaps between lines.** Make the brush slightly bigger, or the pen size slightly smaller.
- **Thin white lines between rows.** The brush in your app is narrower than the pen size.
  Set it to the size the panel shows, or 1 px bigger.
- **Lines turn into right-clicks or ⌘-clicks.** Let go of ⌃⌥⌘ after pressing ⌃⌥⌘↩. DrawBot
  waits for you to release modifier keys before it touches the mouse, but only for so long.
- **It pauses right away with "Mouse moved".** Hands off, or turn off *Pause if I move the
  mouse*.
- **Color Learn picked the wrong color.** Answer **No** at the check and give it one more
  example. If you taught it by typing and the shade is still wrong, the app is changing what's
  typed; teach it by clicking (or with different fields) instead.
- **A lesson keeps failing.** Every lesson is logged in
  `~/Library/Application Support/DrawBot/Lessons/`: what DrawBot recorded, what it concluded,
  and how its try went. The log is the quickest way to see what went wrong, and
  `Tools/colorlearn-harness` can replay it.
- **A hotkey doesn't work.** Another app probably owns that combination; DrawBot says so in its
  panel when that happens.

## Project layout

The code is a Swift package with three modules, split so the interesting logic can be tested
without touching the real mouse:

| Module | What's in it |
|---|---|
| `Sources/DrawBotCore` | Pure logic, no AppKit: image loading, color maths, k-means quantization, stroke planning, time estimates, and Color Learn's analysis (`ColorLearn.swift` for the data types, `ColorLearner.swift` for the learning). |
| `Sources/DrawBotSystem` | The macOS layer: synthetic mouse events and the drawing engine, the Color Learn input replayer, permissions, global hotkeys, window inspection, app activation. |
| `Sources/DrawBot` | The app itself: menu-bar item, control panel (SwiftUI), canvas selection overlay, prompts, progress display, Test Canvas, the input recorder, and the Color Learn lesson flow. |
| `Tools` | Developer tools for Color Learn: a page recorder for web paint apps and `colorlearn-harness`, which runs the learner on recorded demonstrations. See [Tools/README.md](Tools/README.md). |

`SPEC.md` is the original design spec, which goes into coordinate systems, focus rules and the
drawing engine's timing in more detail.

## Running the tests

```sh
swift test
```

The Core tests include simulated users teaching simulated color pickers: a Photoshop-style
square and hue strip, RGB sliders, a macOS-style color wheel, hex fields, RGB fields with a
typo fixed by backspace, and pasting. They check that DrawBot picks the right explanation and
lands within a few RGB units of the target color.

`RecordedPickerTests` replays real demonstrations recorded in web paint apps, including the
mistakes that used to break the learner. The System tests drive the drawing engine and the
replayer against a fake event sink, so nothing moves your real mouse.

## Known limitations

- DrawBot draws in straight horizontal runs on a grid. It's a printer, not an artist.
- Color Learn remembers screen positions. If your app's color picker moves, teach it again.
- Except when learning preset colors, DrawBot doesn't look at the screen. If an app changes the value you type (PaintZ does this with hex
  codes), DrawBot types it the same way and gets the same wrong color. The check step catches
  this, and DrawBot then suggests teaching another way.
- DrawBot can't see whether a picker actually opened. It relies on timing, and on you closing
  the picker at the end of each demonstration.
- A hue strip is assumed to have its red seam at the ends. PaintZ's sits 15° in from the
  bottom, so in PaintZ, reds within about 15° of pure red come out slightly orange when the
  picker was taught by clicking. Teach it by typing values to get them exact.
- This app is macOS only: it relies on Quartz event posting and the macOS window list. For
  Windows, see [`windows/`](windows/README.md).
