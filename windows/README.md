# DrawBot for Windows

This is the Windows port of DrawBot. It paints a picture in any drawing app (Paint, Krita, GIMP,
Photoshop, a browser paint app) by moving the real mouse. It works the same way as the macOS
app described in the [main README](../README.md): you pick an image and drag a rectangle over the
canvas, and DrawBot draws one color at a time. Color Learn can select the colors for you.

> DrawBot drives your actual mouse. Keep your hands off it while it draws. Moving the mouse
> pauses the drawing, and Esc stops it.

## Building

You need Windows 10 or 11 and a Roslyn C# compiler. Any of these provide one:

- Visual Studio 2019 or later (any edition), or
- the free **Build Tools for Visual Studio** with the ".NET desktop build tools" workload.

There's nothing else to install. The app targets .NET Framework 4.8, which every Windows 10 and
11 machine already has.

```powershell
cd windows
.\build.ps1          # builds build\DrawBot.exe and build\DrawBotTests.exe
.\build.ps1 -Test    # builds, then runs the unit tests
.\build\DrawBot.exe
```

`DrawBot.exe` is a single file, so you can copy it anywhere. Settings and learned color pickers
are stored in `%APPDATA%\DrawBot`.

## Using it

DrawBot lives in the notification area (the paintbrush icon). Closing its window only hides it,
so the hotkeys keep working. Use **Quit DrawBot** in the icon's menu to quit.

1. **Open your drawing app** with a white canvas at 100% zoom.
2. **Choose an image**: *Choose Image…*, drop a file onto the window, or paste one (Ctrl+V).
3. **Select the canvas** with *Select Canvas* or **Ctrl+Alt+Shift+S**, then drag a rectangle over
   the part of the canvas to paint. Esc cancels.
4. **Tune it** while you watch the preview. The settings are the same as on the Mac: colors
   (1 makes a one-color doodle), merge similar, pen size, speed, strokes (A\* paths or top to
   bottom), color order, countdown, pause on mouse move and skip near-white. Click a swatch to
   skip that color.
5. **Start Drawing.** For each color, DrawBot shows the color with its hex, RGB, HSB and HSL
   values. Select that color in your app, then click **Continue** or press
   **Ctrl+Alt+Shift+Enter**.

No paint app handy? **Test Canvas** opens a white DrawBot window with its own little color
picker, so you can try drawing and Color Learn there.

### Color Learn

This works as on the Mac. Select a canvas, click **Learn Color Picker…**, then select the two
colors DrawBot asks for in your app's color picker, pressing **Done** after each. You can click,
drag, type the hex code or RGB values, or paste them. DrawBot then selects a third color by itself
and asks whether it worked. For apps that only have a few preset color buttons, click **Preset
colors…** in the prompt and click each button once.

In a browser, DrawBot keeps one learned picker per website. It reads the site from the address
bar through UI Automation, or from the window title if that fails.

## Hotkeys

| Keys | What it does |
|---|---|
| Ctrl+Alt+Shift+P | Show the DrawBot window (pauses a drawing first) |
| Ctrl+Alt+Shift+S | Select the canvas |
| Ctrl+Alt+Shift+Enter | Continue / Resume / Done (whenever DrawBot is waiting for you) |
| Ctrl+Alt+Shift+. | Stop |
| Esc | Stop while drawing; cancel a countdown, a canvas selection or an automatic color selection |

DrawBot only claims Esc while it's busy. If another app already owns one of the hotkeys, the
DrawBot window says so; the buttons still work.

## How it differs from the Mac version

- **No permissions to grant.** Windows lets any app send mouse input and watch the keyboard.
  There are two limits instead:
  - **Apps running as administrator.** Windows won't let a normal app click into them. DrawBot
    warns you when the app under the canvas runs elevated. Run DrawBot as administrator too.
  - **Locked or disconnected desktop.** Input only reaches an unlocked desktop that is on
    screen. While your screen is locked, an administrator prompt is open, or a Remote Desktop
    session is disconnected, DrawBot refuses to start, and it stops if this happens mid-drawing.
- **Pixels, not points.** DrawBot is per-monitor DPI aware, so the pen size, canvas readout and
  everything else are in physical screen pixels. At 100% zoom, set your app's brush to the
  size DrawBot shows. On a display scaled above 100%, apps that measure brushes in scaled units
  want the smaller number the window shows.
- **Hotkeys** use Ctrl+Alt+Shift instead of ⌃⌥⌘. When Color Learn records shortcuts, Ctrl takes
  the place of ⌘ (Ctrl+A, Ctrl+V), and Shift+Insert counts as a paste.
- **Typing** is replayed as the key that types each character on your current keyboard layout,
  or as a Unicode character if no plain key does.
- **Preset colors** need no screen-recording permission. DrawBot hides its own windows from its
  screenshots.
- **Images:** PNG, JPEG, BMP, GIF, TIFF and ICO always load. WebP and HEIC load when their
  Windows codecs are installed.

## Testing on your machine

The unit tests (85 of them) cover the same ground as the Swift tests: color math, quantizing,
stroke planning, Color Learn against simulated pickers, and the drawing engine and replayer
against a fake input system. They never touch the real mouse.

```powershell
.\build.ps1 -Test
```

`DrawBot.exe` also has end-to-end self tests that drive the whole app. Each one writes a log and
images to `--out` (default `%TEMP%\DrawBotSelfTest`) and exits with 0 on success:

```powershell
.\build\DrawBot.exe --selftest --out .\selftest           # draws into the Test Canvas, checks every cell
.\build\DrawBot.exe --selftest-learn --out .\selftest     # teaches Color Learn by clicking, then draws automatically
.\build\DrawBot.exe --selftest-paint --out .\selftest     # one-color doodle in classic Microsoft Paint
```

These move the real mouse, so start them from an unlocked desktop and keep your hands off the
mouse. Add `--speed fast` (or `careful`, `ludicrous`) to try other speeds. Add `--virtual` to
deliver the same input as window messages instead of real mouse input. That works even on a
locked or disconnected desktop and tests everything except Windows' input queue.

## Project layout

| Folder | What's in it |
|---|---|
| `src/Core` | Pure logic, ported one-to-one from `Sources/DrawBotCore`: color math, image loading and rasterizing, k-means quantization, A\* stroke planning, time estimates, Color Learn (learner, profiles, preset colors), JSON. |
| `src/Win` | The Windows layer: `SendInput` mouse driver and drawing engine, Color Learn replayer, low-level input hooks and recorder, hotkeys, window inspection, app activation, screenshots, browser site detection. |
| `src/App` | The WinForms app: tray icon, control window, canvas selection overlay, color prompt, progress display, Test Canvas, the Color Learn lesson, and the self tests. |
| `tests` | Unit tests and a tiny test runner. |

## Known limitations

- The same as on the Mac: DrawBot draws on a grid, and Color Learn remembers screen positions.
- If a drawing has single dots closer together than Windows' double-click distance (pen sizes
  under about 4 px), an app may see two of them as a double click.
- Windows only delivers input to an unlocked desktop that is on screen (see above).
