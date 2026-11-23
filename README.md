# TheGrid

A ring of app windows around you, for Xreal Air glasses on a Mac.

The glasses are a 1920x1080 monitor sitting above the Mac's own screen. A monitor that size holds
three windows at a stretch, which is not what wearing a screen on your face promises. TheGrid
makes that display a window onto a much larger ring: three slots across and two down are in view,
and the ring carries on to either side, right the way round and back to where it started. Three
fingers on the trackpad turn it, and the windows glide from slot to slot.

The windows are your real windows. There is no streaming and no drawing of fake app pictures:
TheGrid moves Safari, your terminal and your editor around the ring with the Accessibility API,
so everything on the glasses is live, clickable and typed into as normal.

```
          . . . [ 11A ][ 12A ][  1A ][  2A ][  3A ][  4A ] . . .     the ring, 12 slots round
          . . . [ 11B ][ 12B ][  1B ][  2B ][  3B ][  4B ] . . .
                        |<------ the glasses ------>|
```

## Building it

```sh
./scripts/build-app.sh
open dist/TheGrid.app
```

An app bundle rather than the bare binary, because macOS hangs Accessibility permission on an
app: run from a terminal, the permission would land on the terminal instead and every shell on
the machine could move windows. It is signed ad hoc, which is enough to run it here.

The tests need no glasses, no windows and no permission:

```sh
swift run gridtests
```

`TheGrid --doctor` prints what the app can see from where it stands: whether it has permission,
which screens it found and which windows it would be willing to take.

The same binary drives the copy already running, which is how the grid is tested without a hand
on the trackpad, and what a keyboard shortcut would call:

```sh
TheGrid --pull            # the front window onto the ring
TheGrid --pull Safari     # that app's front window instead
TheGrid --turn 2          # two slots right, -2 for left
TheGrid --release         # every window back where it was
TheGrid --state           # what the ring is holding, as JSON
```

`--state` gives each window's slot, where the grid asked it to be and where it actually is, which
is how you tell an app that refused a size from a grid that asked for the wrong one.

## Setting it up

**Accessibility.** TheGrid moves other apps' windows, and macOS allows that only with
permission. The first launch asks and opens System Settings > Privacy & Security >
Accessibility; switch TheGrid on. After a rebuild macOS may stop trusting the new signature: if
the ring stops moving windows, untick and retick TheGrid there.

**The trackpad.** macOS may want three fingers for itself. Open System Settings > Trackpad >
More Gestures: if *Swipe between full-screen applications* is set to three fingers, change it to
**four**, or a sideways swipe will turn the ring and change Space at the same time. Three-finger
drag, in Accessibility > Pointer Control > Trackpad Options, takes the gesture outright and has
to be off. Nothing else needs changing: TheGrid only wants sideways swipes, so Mission Control on
three fingers up can stay as it is.

If you would rather leave the system gestures alone, the menu's *Turn the ring with* has
**Option and scroll**: hold Option and scroll, which TheGrid swallows so nothing under the
pointer scrolls with it. Control-Option-Left and Control-Option-Right always step one slot,
whatever else is set.

## Using it

- **Turn the ring**: three fingers across the trackpad, or Option and scroll. A flick carries on
  and settles onto the nearest slot; it never stops halfway between two.
- **Put a window on the ring**: drag it from the Mac's screen up onto the glasses and let go. A
  dashed outline shows the slot it will land in. A slot already taken passes the window to the
  nearest free one rather than stacking them.
- **Resize a window**: drag its edge, as you would anywhere. It snaps to the slots it now covers,
  up to three across and two down, and the ring remembers how much room it holds.
- **Move a window within the ring**: drag it to another slot. Dragging it off the glasses and
  back onto the Mac's screen takes it off the ring, and leaves it where you dropped it.
- **Hand everything back**: the menu bar item has *Hand every window back*, which restores every
  window to the size and place it had before the grid took it. Unplugging the glasses and
  quitting both do the same, so you are never left hunting for a window parked off the side of a
  screen that has gone.

The menu also sets the shape of the grid: how many slots across and down are in view, and how
many go round the ring. Six slots round is a tight circle; twenty-four is a wall. *Sensitivity*
sets how far a swipe turns it and how much scrolling makes a slot, and *Backdrop* how solid the
panel behind the slots is, from solid black to a faint wash with the desktop coming through.

## What the glasses taught it

Three things only turned up with the hardware on, and each is a line in the code that looks
arbitrary until you know why:

- **The glasses have a menu bar.** With *Displays have separate Spaces* on, which is the default,
  every screen carries one, and macOS quietly drops any window asked to sit under it 30 points
  lower. The ring is laid out in the screen's usable area, not its bounds, or every slot in the
  top row would be out of line with the row beneath.
- **A window cannot be moved entirely out of sight.** Ask for a position further off than the
  edge and macOS keeps 40 points of the window on the nearest screen, measured and consistent.
  So the grid leaves a 40 point margin down each side of the glasses, masks it with a strip that
  sits above every window, and parks the far side of the ring underneath: a window on its way out
  slides behind the edge instead of pinning a stripe of itself there.
- **Position, then size, then position.** An app clamps a window to the screen it is on at that
  moment, so sizing first asks for a window taller than the Mac's own screen and gets the Mac's
  screen height back. Moving it onto the glasses first means the size is measured against the
  glasses. Even then an app can be too busy to answer, so the housekeeping compares where each
  window is with where it should be and asks again, three times, before letting it be.

## How it works

`GridCore` is the ring, and knows nothing about macOS beyond CoreGraphics' idea of a rectangle:
where every slot sits at a given scroll position, which ones are taken, how a window's size
becomes a span of slots, and how a flick becomes a glide. It is all pure, so the tests run on any
Mac with no glasses, no windows and no permission.

- **The ring has no ends.** A column's distance is measured the short way round, so turning left
  from the first slot arrives at the last rather than travelling eleven slots to get there.
- **Out of sight, just out of reach.** A window on the far side of the ring is held a little way
  past the edge of the glasses rather than at its true position thousands of points away. It
  costs nothing to keep, and the window slides in when you turn back to it instead of appearing.
- **Nothing waits for an app.** Accessibility calls are round trips to other processes, and one
  slow app would stall the gesture. The ring only ever says where windows should be;
  `WindowMover` applies that on its own thread, keeps the newest position for each window and
  drops the ones overtaken while an app was thinking. A scroll setting ninety positions a second
  to an app that can manage twenty simply skips the seventy nobody would have seen.
- **The chrome is two windows.** The grid of empty slots is drawn *behind* every app window, so
  the apps sit in the grid rather than under a frame drawn over them; only the drop outline sits
  on top. Neither takes a click, because every click on the glasses belongs to a real window.

## Where it is rough

- **The three-finger gesture works, and the sensitivity is a matter of taste.** The touches come
  through as gesture events and are read from both an event tap and a global monitor, whichever
  the system offers them to. Measured over nine real swipes, a comfortable one covers about a
  fifth of the trackpad, which at the default of three slots to a full swipe is 0.6 of a slot,
  and the momentum carries it to exactly one. So one swipe, one slot. Turn *A swipe turns N
  slots* up if you want a flick to cross the ring faster, or run the app from a terminal with
  `THEGRID_LOG=1` to watch what the trackpad is actually sending.
- **How smooth the glide is depends on the apps on the ring.** Measured on this Mac, a move costs
  Finder and Discord about 0.1 ms, and Safari 5.2 ms, with a worst case of 70 ms when it is busy.
  The mover drops frames rather than waiting, so the ring itself never stutters and the light
  windows glide at full rate, but a heavy one can lag a frame or two behind the others.
- **A window may span past the edge of the view.** A two-slot window dropped on the last visible
  column covers the next column round, which is out of sight until you turn to it. That is the
  ring working as intended, but it looks like a window running off the edge until you scroll.
- **The grid wants the glasses at 1920x1080, unscaled.** It will use the only external screen it
  finds whatever its size, and any screen you pick from the menu, but the slot sizes are chosen
  for a 16:9 display driven at its own resolution.
