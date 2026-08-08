# Stay Awake

A menu bar switch for macOS sleep. Pick a duration, and your Mac stays up until
it runs out.

<img src="docs/icon.png" width="128" alt="Stay Awake icon">

The whole app is a well-behaved front end for `/usr/bin/caffeinate`. caffeinate
holds a real IOKit power assertion for as long as it is alive, so "keep this Mac
awake for two hours" is just `caffeinate -d -i -s -t 7200`, and "let it sleep
again" is killing that process. No private API, no kernel extension, no
background daemon — **quit the app and the assertion dies with it.**

## Install

### From source — the path with no Gatekeeper in it

One Swift file, one script, nothing beyond the Command Line Tools:

```bash
git clone https://github.com/gowthamrajum/stay-awake.git
cd stay-awake
./build.sh --install     # universal binary, straight into /Applications
```

```bash
./build.sh               # just build into dist/
./build.sh --native      # this Mac's arch only; faster while iterating
```

An app you compiled yourself never gets a quarantine flag, so it simply opens.
This is the recommended route and it takes about a minute.

### From the DMG

Grab it from [Releases](https://github.com/gowthamrajum/stay-awake/releases),
open it, drag **Stay Awake** to Applications. Then expect this on first launch:

> "Stay Awake" can't be opened because Apple cannot check it for malicious
> software.

That is Gatekeeper, not a corrupt download. The build is signed ad-hoc — there
is no paid Apple Developer ID behind this project — and macOS refuses ad-hoc
binaries that arrive carrying a download's quarantine flag.

**On macOS 15 and later, right-clicking → Open does not get past this.** Apple
removed that bypass. Two things actually work:

```bash
xattr -dr com.apple.quarantine "/Applications/Stay Awake.app"
```

Strip the flag and it opens normally from then on. Or, without a terminal: try
to open it once, let it be blocked, then go to **System Settings → Privacy &
Security**, scroll to **Security**, and click **Open Anyway** next to the
message about Stay Awake.

Both are the same decision — you are vouching for a binary Apple has not
notarised. If you would rather not, build from source above and read the ~600
lines you are running.

## Using it

The bulb in the menu bar is the whole status display:

| Menu bar | Meaning |
| --- | --- |
| Outline bulb | Sleep is allowed. Nothing is holding the Mac up. |
| Filled bulb | Something is holding the Mac awake. |
| Filled bulb + `2:15` | 2 hours 15 minutes left. |
| Filled bulb + `45m` | Under an hour — minutes only. |
| Filled bulb + `<1m` | Nearly done. |

**Left-click** opens the menu. **Right-click** (or control-click) is a shortcut
that toggles between *awake indefinitely* and *off*, so the common case never
costs two clicks.

The menu holds everything:

- **Presets** — 15 minutes, 30 minutes, 1, 2, 4, or 8 hours.
- **Until a time…** — type `5:30 PM` or `17:30`. A time that has already passed
  today is read as tomorrow, so "until 6 AM" at midnight means the 6 AM that is
  coming.
- **Indefinitely** — no timer at all.
- **Add 15 minutes / Add 1 hour** — extend what is already running instead of
  restarting it.
- **Turn Off (allow sleep)** — release everything.
- **Allow display to sleep** — keep the machine up but let the screen go dark.
  This is the difference between `caffeinate -d -i -s` and `caffeinate -i -s`;
  toggling it relaunches the assertion so the change takes effect immediately.
- **Launch at Login** — a real `SMAppService` login item (macOS 13+).
- **Open Window** — the same controls in a small window, for when the menu is
  fiddly.

## Somebody else's caffeinate

If a `caffeinate` is running that this app did not start — one you launched in a
terminal, or one another utility left behind — the menu says so:

> Awake — external timer (time unknown)

The app reports it rather than pretending sleep is allowed, but it does **not**
adopt or cancel it. Choosing a duration only replaces *this app's* assertion.
**Turn Off** is the one command that clears external ones too, because that menu
item promises sleep is allowed and it would be lying otherwise.

## How the timer ends

This is the part worth being careful about, and it is where the previous version
of this app got it wrong — the countdown would stick at `<1m` forever and the
icon never went back to unlit.

The state is torn down by three independent paths, because any one of them can
be missed:

1. **caffeinate's own exit.** With `-t` it terminates itself when the time is
   up, and the process's `terminationHandler` is the authoritative signal.
2. **A deadline check on every tick.** If the clock is past the end date, the
   state clears whether or not the handler fired — this alone makes a stuck
   `<1m` impossible.
3. **A liveness check on every tick.** If the process is gone (killed from
   outside, crashed, `pkill`ed), the state clears too.

Redundant on purpose. The failure mode being defended against is an icon that
claims your Mac is awake when it is not, which is worse than a redundant check.

## Layout

```
StayAwake/StayAwake.swift    the entire app (~600 lines of AppKit)
StayAwake/Info.plist         LSUIElement, bundle id, version
Resources/make-icon.swift    draws AppIcon.icns from code
Resources/AppIcon.icns       generated — regenerate, do not hand-edit
build.sh                     swiftc + bundle layout + ad-hoc signature
```

There is no Xcode project and no SwiftPM manifest. A single-file AppKit agent
does not need either, and `swiftc` invoked directly stays legible.

### The icon

The icon is code, not a binary someone has to open a design tool to change — a
warm bulb still burning against a deep indigo night, which is the app's whole
job. Regenerate after editing `make-icon.swift`:

```bash
swift Resources/make-icon.swift
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Each size is drawn at its final pixel dimensions rather than downscaled from one
master, so the 16pt bulb keeps its strokes.

## Releasing

Version lives in `StayAwake/Info.plist`. Bump it, tag it, push the tag:

```bash
git tag v2.1 && git push origin v2.1
```

The workflow builds a universal app on a macOS runner, refuses the release if
the tag and `Info.plist` disagree, and attaches a DMG and a zip to a **draft**
release for you to publish.

## Requirements

macOS 12+ (Launch at Login needs 13+). Universal — Apple silicon and Intel.

## License

MIT
