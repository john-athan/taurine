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
No Xcode project, no dependencies — just `swiftc`.

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
| **Also prevent system sleep** | Not just the display — the whole machine (for long jobs). |
| **Keep awake with lid closed (AC only)** | Off by default — a closed lid sleeps normally. On, and only while awake + plugged in, Taurine holds the lid open too (`pmset disablesleep`, needs admin). Reverts on unplug, toggle-off, or quit. |
| **Auto-off under 20% on battery** | The conscience. Won't drain your laptop overnight. |
| **Start awake at launch** / **Start at login** | Set once, forget. |

> **Lid-closed, carefully.** Ordinary sleep assertions (everything else Taurine
> does) don't survive a shut lid — that's *clamshell* sleep, a separate path. The
> only lever is `pmset disablesleep`, which is system-wide and persistent, so
> Taurine engages it only while awake + on AC and always puts it back. A hard
> crash can leave it set; if a closed lid ever won't sleep, run
> `sudo pmset -a disablesleep 0`. And don't stuff an awake, lid-shut Mac in a bag.

**CLI**

```bash
taurine -- make build     # awake for exactly this command's lifetime
taurine why               # who is keeping this Mac awake right now?
taurine on | off | toggle # drive the running menu bar app
taurine help
```

`taurine -- <command>` is `caffeinate <command>` with a pulse: it prints a bull,
holds display **and** system assertions for the child's life, and lets go the
moment it exits — great in front of a long build or upload.

---

## License

MIT — see [LICENSE](LICENSE). Do what you like; keep the notice.
