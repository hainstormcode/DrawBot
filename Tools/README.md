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

It records mouse events rather than pointer events, because only mouse events carry click
counts. Coordinates are the page's CSS pixels. That's fine: the learner only needs one
consistent coordinate frame.

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
