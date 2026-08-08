## Install

Download the `.dmg`, open it, and drag **Stay Awake** to Applications.

The build is **unsigned** — there is no paid Apple Developer ID behind it — so
the first launch needs one extra step:

> **Right-click** the app in Applications → **Open** → **Open**.

macOS remembers the exception, and every launch after that is a normal
double-click. (Double-clicking first, without the right-click, gives you a
"cannot be opened" dialog with no Open button — that is Gatekeeper, not a broken
download.)

Prefer to build it yourself? It is one Swift file and one script:

```bash
git clone https://github.com/gowthamrajum/stay-awake.git
cd stay-awake && ./build.sh --install
```

## What it does

Lives in the menu bar and holds your Mac awake for a duration you pick — a
preset, a number of hours, or until a specific clock time. It is a front end for
the built-in `caffeinate`, so quitting the app always releases the assertion.
