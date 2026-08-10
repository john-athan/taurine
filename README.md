<div align="center">

# Taurine 🐂

**Keep your Mac awake — with a reason.**

<img src="assets/taurine.gif" alt="Taurine" width="440">

</div>

Most "keep awake" apps are a light switch: on, off, and no idea why the room's
still lit. Taurine fixes the parts that annoy you about the others.

Tell it *why* to stay up and it lets go on its own:

```bash
taurine -- make build      # awake for exactly this command, then done
```

Ask *who's* keeping your Mac awake — Taurine or anything else — and it actually
answers:

```bash
taurine why
```

And while it's holding the line, a bull gallops out of your menu bar to say so.

Ask what your Mac is *spending itself on* and it answers in watts, from the
chip's own energy counters, with no password and nothing running until you open
the panel.

No polling, no network, no analytics. ~15 MB resident, **0 idle timers, 0
sockets** — a number it shows you rather than a claim it makes.

> "Taurine" is the energy-drink amino acid (and *Taurus*, the bull). No
> affiliation with, or endorsement by, any beverage company.

---

## Install

### Homebrew (recommended)

```bash
brew install john-athan/tap/taurine
taurine            # launches the menu bar app
```

That's it — the `taurine` CLI is on your `PATH` immediately, and running it
with no arguments launches the menu bar app. Homebrew builds from source on
your machine, so there's **no "unidentified developer" Gatekeeper prompt** and
nothing to notarize.

To also keep it in `/Applications` (for the login-item toggle):

```bash
cp -R "$(brew --prefix taurine)/Taurine.app" /Applications/
```

### Make (no Homebrew)

```bash
git clone https://github.com/john-athan/taurine && cd taurine
make install       # builds, installs to /Applications, links the CLI, launches
```

`make uninstall` reverses it.

### Fully manual

```bash
./build.sh
cp -R Taurine.app /Applications/ && open /Applications/Taurine.app
sudo ln -sf /Applications/Taurine.app/Contents/MacOS/taurine /usr/local/bin/taurine
```

No `sudo`? Link into a dir you own instead:

```bash
mkdir -p ~/.local/bin
ln -sf /Applications/Taurine.app/Contents/MacOS/taurine ~/.local/bin/taurine
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Requires macOS 13+ and the Xcode command line tools (`xcode-select --install`).
No Xcode project, no dependencies, just `swiftc`.

`make test` builds the app into a test binary and runs it. Same toolchain, no
package manager, no network. See
[ADR 1](docs/adr/0001-tests-without-a-package-manager.md).

---

## Use

**Menu bar** — click the ⚡ bull for the menu, or hit the global hotkey
**⌃⌥⌘R** from anywhere to toggle.

The menu gives you:

| Item | What it does |
|---|---|
| **Toggle** | Classic on/off. Bull gallops in, bull dozes off. |
| **Keep awake for…** | 15 min / 30 min / 1 h / 2 h, then auto-off. |
| **Stay awake until an app quits…** | Pick a running app; Taurine releases the instant it exits. |
| **Why is my Mac awake?** | Live list of every process holding a sleep assertion. |
| **What is this Mac doing?** | The activity panel: cores, watts, memory, disk, network. Costs nothing until you open it. |
| **Things Apple got wrong** | Small fixes for settings the system should have had. Currently: scroll direction per device. |
| **Also prevent system sleep** | Not just the display — the whole machine (for long jobs). |
| **Keep awake with lid closed (AC only)** | Off by default — a closed lid sleeps normally. On, and only while awake + plugged in, Taurine holds the lid open too (`pmset disablesleep`, needs admin). Reverts on unplug, toggle-off, or quit. |
| **Auto-off under 20% on battery** | The conscience. Won't drain your laptop overnight. |
| **Charge limit** | Stop charging at 60–90% to spare the cell. One admin prompt to install, then free forever. |
| **Start awake at launch** / **Start at login** | Set once, forget. |

> **Lid-closed, carefully.** Ordinary sleep assertions (everything else Taurine
> does) don't survive a shut lid — that's *clamshell* sleep, a separate path. The
> only lever is `pmset disablesleep`, which is system-wide and persistent, so
> Taurine engages it only while awake + on AC and always puts it back. A hard
> crash can leave it set; if a closed lid ever won't sleep, run
> `sudo pmset -a disablesleep 0`. And don't stuff an awake, lid-shut Mac in a bag.

---

## What is this Mac doing? 📈

Everything `mactop` shows you in a terminal, in a panel that drops out of the
menu bar: per-cluster and per-core load with the frequency each cluster is
actually running at, GPU utilisation, CPU, GPU and Neural Engine watts, memory
split into app, wired and compressed with swap when swap is in use, and disk and
network rates with a minute of history.

**No password.** Every other Mac power monitor shells out to `powermetrics`,
which will not run without root. Taurine reads the same energy counters directly
through IOReport, which an ordinary process may do, so the panel never asks for
anything. See [ADR 3](docs/adr/0003-ioreport-for-power-without-root.md).

**No cost while it is shut.** Nothing samples until the panel is on screen.
Opening it creates the app's only repeating timer and opens the probes; closing
it cancels the timer, closes the probes and throws the history away. The badge
under the menu proves it: open the panel and it reads `1 timer`, close it and it
reads `0 timers` again. See
[ADR 2](docs/adr/0002-the-activity-panel-costs-nothing-while-closed.md).

Anything this Mac cannot answer is left out rather than drawn as a zero, with a
line at the bottom naming what is missing and why.

---

## Things Apple got wrong ⚙️

A shelf for settings the system should have shipped correctly. The rule for
what belongs here: small, local, reversible, and obviously right once you see
it.

**Scroll direction follows the device.** macOS has one scroll direction for the
whole machine, so anyone using a trackpad and a wheel mouse has to pick which of
the two feels wrong. Switch this on and each device gets the direction it
should have had: trackpads and the Magic Mouse scroll naturally, wheel mice
scroll the traditional way. Flip the system setting and the correction moves to
the other class, so the feature works the same for people who prefer the
traditional feel everywhere.

Off by default, because modifying scroll events needs Accessibility permission,
and Taurine would rather ask for nothing until you ask it to. macOS grants that
permission to a specific build of a binary, so a rebuild or an upgrade means
granting it again: remove Taurine from the Accessibility list with the minus
button and add it back. The menu item says so when that has happened, instead of
looking switched on and doing nothing. See
[ADR 4](docs/adr/0004-scroll-direction-belongs-to-the-device.md).

---

## Charge limit 🔋

Lithium cells age fastest sitting at 100%. Taurine can stop charging at 80% and
hold there while you stay plugged in.

```bash
taurine batt              # what's it doing right now?
taurine batt 80           # stop charging at 80%
taurine batt off          # back to charging all the way
taurine batt unlock       # escape hatch, see below
```

Enable it once from **Charge limit → Enable charge limiting…** in the menu. That
installs a small root LaunchDaemon (the same binary, run with `--charge-daemon`)
and asks for your password once. After that, changing the limit is just a number
written to a file the daemon is watching, so it never prompts again.

**How it works.** The System Management Controller has a key that decides whether
the wall adapter may charge the cell: `CHTE` on macOS 26+, `CH0B`+`CH0C` before
that. Taurine probes which one your Mac has rather than checking a version
number, and talks to it directly through IOKit. There's no bundled `smc` binary
and nothing gets shelled out.

**It costs you nothing to run.** No timers, no polling, no 30-second wake-ups.
The daemon sleeps in `mach_msg` at 0% CPU and is woken only by the kernel: a
power-source change, a wake from sleep, or you picking a new limit. It writes to
the SMC a couple of times a day, and a 3% deadband below the limit keeps it from
flapping at the boundary.

> **The escape hatch.** The inhibit bit lives in the SMC, not in the daemon, so a
> hard kill at the wrong moment could leave a Mac that won't charge. `KeepAlive`
> plus a recover-on-start covers this, and any clean exit releases the bit. If it
> ever does get stuck, `taurine batt unlock` clears it unconditionally. Run
> `make uninstall` and the daemon is released before its binary is removed.

**CLI**

```bash
taurine -- make build     # awake for exactly this command's lifetime
taurine why               # who is keeping this Mac awake right now?
taurine on | off | toggle # drive the running menu bar app
taurine batt 80           # stop charging at 80%
taurine help
```

`taurine -- <command>` is `caffeinate <command>` with a pulse: it prints a bull,
holds display **and** system assertions for the child's life, and lets go the
moment it exits — great in front of a long build or upload.

---

## How it is built

Decisions worth writing down live in [docs/adr](docs/adr/README.md): why there
is no package manager, why the activity panel costs nothing while it is closed,
why power comes from IOReport rather than `powermetrics`, and why scroll
direction belongs to the device.

---

## License

MIT — see [LICENSE](LICENSE). Do what you like; keep the notice.
