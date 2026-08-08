## Install

Download the `.dmg`, open it, drag **Stay Awake** to Applications.

On first launch macOS will say:

> "Stay Awake" can't be opened because Apple cannot check it for malicious
> software.

That is Gatekeeper, not a corrupt download. This build is signed ad-hoc — there
is no paid Apple Developer ID behind the project — and macOS refuses ad-hoc
binaries that arrive with a download's quarantine flag.

**On macOS 15 and later, right-clicking → Open does not get past this.** Apple
removed that bypass. Two things actually work:

```bash
xattr -dr com.apple.quarantine "/Applications/Stay Awake.app"
```

Strip the flag and it opens normally from then on. Or, without a terminal: try
to open it once, let it be blocked, then go to **System Settings → Privacy &
Security**, scroll to **Security**, and click **Open Anyway**.

### Or skip Gatekeeper entirely

An app you compile yourself is never quarantined, so it just opens:

```bash
git clone https://github.com/gowthamrajum/stay-awake.git
cd stay-awake && ./build.sh --install
```

One Swift file, one script, no dependencies beyond the Command Line Tools.

## What it does

Lives in the menu bar and holds your Mac awake for a duration you pick — a
preset, a number of hours, or until a specific clock time. It is a front end for
the built-in `caffeinate`, so quitting the app always releases the assertion.

The bulb tells you the state at a glance: outline means sleep is allowed, filled
means something is holding the Mac up, and a timed hold shows its countdown
beside it (`2:15`, `45m`, `<1m`).
