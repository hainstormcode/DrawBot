# Colour Learn test tools

These are for developing Colour Learn, not for using DrawBot.

DrawBot learns a colour picker by watching someone use it. Debugging that inside the real app
is slow: every rebuild has to be granted Accessibility again, and you have to teach it by hand
each time. These tools split the learner off so you can record a demonstration once and replay
it against the learner as often as you like.

## `page-recorder.js`

A snippet that records mouse and keyboard input in a web page, in the format the harness reads.
Paste it into the browser console on a web paint app (or inject it with a browser automation
tool), demonstrate a colour, then run `copy(JSON.stringify(window.__dbrec.take()))` to copy the
events.

It records pointer events, because many pickers cancel `pointerdown`, and then the browser never
sends `mousedown`. Pointer events carry no click count. That's fine: the learner works out
double and triple clicks from timing. Coordinates are the page's CSS pixels, and the learner
only needs one consistent coordinate frame.

## `colorlearn-harness`

Runs DrawBot's real learner (`ColorLearner` in DrawBotCore) on recorded demonstrations and
prints what it learned, plus the exact input it would replay for some test colours.

```sh
swift run colorlearn-harness < session.json
```

The input format is documented at the top of `ColorLearnHarness/main.swift`. In short: the
canvas rectangle, the screen rectangle, one entry per demonstrated colour with its recorded
events, and a list of test colours. The output is JSON. On success it has `summary` (what
DrawBot understood), `key` (the interpretation it picked), and `actions` (clicks, drags and
keystrokes per test colour). On failure it has `message`, exactly what the user would be told.

To close the loop, play the `actions` back into the page (with your browser automation tool of
choice) and read the colour the picker ended up with. That's how the web-app regression tests
in `Tests/DrawBotCoreTests/RecordedPickerTests.swift` were made.

## Gotchas when driving a page from automation instead of a real mouse

These tripped up the Sumo Paint and PaintZ tests. They are limits of the automation, not of
DrawBot, which records and replays real OS-level input:

- **"Type text" often inserts text without key events.** The page never sees keystrokes, and
  some fields don't commit the value. Press keys one at a time instead.
- **⌘A may not select a field's contents.** A real keyboard triggers the browser's Select All,
  but a synthetic key event may not. Triple-click the field instead (plenty of people do).
- **A "drag" may be just a press and a release** with no movement in between. Pickers that
  track movement never see it, so judge drag-based replays (colours at the very edge of a
  square or slider) in an app that tracks the press and release positions, or in DrawBot itself.
- **Dialogs animate.** PaintZ ignores its colour button for about a second after its dialog
  closes. DrawBot waits for 1.5 s without clicks or key presses before it replays a picker;
  leave the same gap between test steps.
