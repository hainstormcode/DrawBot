# Color Learn test tools

These are for developing Color Learn, not for using DrawBot.

DrawBot learns a color picker by watching someone use it. Debugging that inside the real app
is slow: every rebuild has to be granted Accessibility again, and you have to teach it by hand
each time. These tools split the learner off so you can record a demonstration once and replay
it against the learner as often as you like.

## `page-recorder.js`

A snippet that records mouse and keyboard input in a web page, in the format the harness reads.
Paste it into the browser console on a web paint app (or inject it with a browser automation
tool), demonstrate a color, then run `copy(JSON.stringify(window.__dbrec.take()))` to copy the
events.

It records pointer events, because many pickers cancel `pointerdown`, and then the browser never
sends `mousedown`. Pointer events carry no click count. That's fine: the learner works out
double and triple clicks from timing. Coordinates are the page's CSS pixels, and the learner
only needs one consistent coordinate frame.

## `DrawBotTestRig.app` (real OS-level input)

A separate little app that plays scripted **real** mouse and keyboard input with DrawBot's own
`InputReplayer`, while DrawBot's own `InputRecorder` records it. This tests the parts the browser
tools can't: OS-level events, real drags, real keystrokes, real click counts.

```sh
./scripts/build_testrig.sh
open -n -W build/DrawBotTestRig.app --args /path/to/script.json
```

The script format is at the top of `TestRig/main.swift` (`record`, `stop`, `play`, `move`,
`sleep`). `play` takes the same actions `colorlearn-harness` prints, so the loop is: record two
demonstrations with the rig, run `colorlearn-harness` on the recordings (it accepts the rig's
`inputs` directly), and play the learned actions back with the rig.

It needs its own Accessibility permission, which survives rebuilding DrawBot. **It's a
development tool**: anything that can write a script for it can make it click and type, so
remove its permission when you're done.

To find web-page coordinates on screen, add a `pointermove` listener that records
`clientX/screenX`, and have the rig `move` the cursor over the page.

## `colorlearn-harness`

Runs DrawBot's real learner (`ColorLearner` in DrawBotCore) on recorded demonstrations and
prints what it learned, plus the exact input it would replay for some test colors.

```sh
swift run colorlearn-harness < session.json
```

The input format is documented at the top of `ColorLearnHarness/main.swift`. In short: the
canvas rectangle, the screen rectangle, one entry per demonstrated color with its recorded
events, and a list of test colors. The output is JSON. On success it has `summary` (what
DrawBot understood), `key` (the interpretation it picked), and `actions` (clicks, drags and
keystrokes per test color). On failure it has `message`, exactly what the user would be told.

To close the loop, play the `actions` back into the page (with your browser automation tool of
choice) and read the color the picker ended up with. That's how the web-app regression tests
in `Tests/DrawBotCoreTests/RecordedPickerTests.swift` were made.

## Gotchas when driving a page from automation instead of a real mouse

These tripped up the Sumo Paint and PaintZ tests. They are limits of the automation, not of
DrawBot, which records and replays real OS-level input:

- **"Type text" often inserts text without key events.** The page never sees keystrokes, and
  some fields don't commit the value. Press keys one at a time instead.
- **⌘A may not select a field's contents.** A real keyboard triggers the browser's Select All,
  but a synthetic key event may not. Triple-click the field instead (plenty of people do).
- **A "drag" may be just a press and a release** with no movement in between. Pickers that
  track movement never see it, so judge drag-based replays (colors at the very edge of a
  square or slider) in an app that tracks the press and release positions, or in DrawBot itself.
- **Dialogs animate.** PaintZ ignores its color button for about a second after its dialog
  closes. DrawBot waits for 1.5 s without clicks or key presses before it replays a picker;
  leave the same gap between test steps.
