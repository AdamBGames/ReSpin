# ReSpin

<img src="respin.png" alt="ReSpin logo" width="128" height="128">

A backup/rebuild tool that works on **Arch, Debian/Ubuntu, Fedora/RHEL,
openSUSE, Alpine, and Void** - the package-manager families covering the
large majority of DistroWatch's most-visited distros (Mint, MX Linux,
EndeavourOS, Debian, Ubuntu, Fedora, Zorin, Manjaro, Pop!_OS, openSUSE,
Arch, CachyOS, Rocky/Alma, and more all fall into one of these six).
ReSpin auto-detects the right package manager and drives that one, so app
installs never depend on one specific distro or image. Also does a
one-shot fix for Chromium/Electron/QtWebEngine apps - Falkon, Discord,
VS Code, etc. - that silently refuse to open.

Rather than reinstalling from a hardcoded package list, `respin backup`
snapshots whatever is *actually* explicitly installed on the box right now,
so `respin reinstall` always rebuilds the machine as it really was.
Backups aren't portable *across* distros - package names differ too much
between package managers for that - but the tool itself is: the same
script and GUI work unmodified on any of the six, each driving its native
package manager.

## Why ReSpin

ReSpin was designed with [Webtop](https://github.com/linuxserver/docker-webtop)
in mind. I've had to respin fresh Webtop instances more times than I'd
like - after Docker updates, new image versions, and everything in
between - and rebuilding everything by hand every time gets old fast.
Webtop's built-in package install option didn't make that easier either:
in my experience it doesn't always work, can hang, or simply breaks
outright for apps that use Chromium or Electron, like Discord. That
combination is exactly why I built this. That said, ReSpin isn't
Webtop-specific - it should work fine on any of the six supported distro
families, containerized or not.

## Supported distros

| Distro family                        | Package manager | Explicit-install list | AUR/foreign equivalent |
| ------------------------------------- | ---------------- | ---------------------------------------- | ----------------------- |
| Arch, Manjaro, EndeavourOS, CachyOS   | `pacman`          | `pacman -Qqe`                             | AUR, via auto-bootstrapped `yay` |
| Debian, Ubuntu, Mint, Pop!_OS         | `apt`             | `apt-mark showmanual`                     | none - Flatpak covers this instead |
| Fedora, RHEL, Rocky, Alma, Nobara     | `dnf`             | `dnf repoquery --userinstalled`           | none - Flatpak covers this instead |
| openSUSE (Leap / Tumbleweed)          | `zypper`          | full installed set (no manual/auto split) | none - Flatpak covers this instead |
| Alpine                                 | `apk`             | `/etc/apk/world`                          | none - Flatpak covers this instead |
| Void                                   | `xbps`            | `xbps-query -m`                           | none - Flatpak covers this instead |

openSUSE is the one exception in that table: `zypper` doesn't track
"explicitly requested" vs. "pulled in as a dependency" the way the others
do, so its backup snapshots the *entire* installed set rather than just
what you asked for. Harmless on reinstall, just a slightly larger package
list than the other five produce.

Detection happens automatically at startup (`respin pkg-manager` prints
what it found). If none of the six are present, every command that needs
one fails fast with a clear error instead of silently doing nothing.
Gentoo (portage), Slackware, and Solus (eopkg) aren't supported - their
package models (source-based builds, no explicit/dependency split) don't
fit this tool's snapshot-and-reinstall approach cleanly.

## Flatpak

**Flatpak + Flathub are installed on every distro** as a portable fallback
so app availability never depends on how complete that distro's native
repos are. `respin flatpak-setup` (also a button in the GUI, and step 5 of
`reinstall`) installs `flatpak` via the native package manager, adds the
Flathub remote (system scope, falling back to user scope if there's no
system D-Bus), and tells you to **log out and back in** -
the app-menu integration and portals need a fresh session to register
correctly the first time.

## Why apps stop opening

Electron apps (Discord, VS Code) and QtWebEngine apps (Falkon) leave behind
`SingletonLock`/`SingletonSocket`/`SingletonCookie` files and Chromium-style
caches (`Cache`, `GPUCache`, `Code Cache`, ...). After an unclean shutdown
the app thinks another instance is already running, tries to signal it over
a dead socket, and just exits - no window, no error. Corrupted GPU shader
caches (`~/.cache/mesa_shader_cache`) cause similar blank/crashing windows.
`respin fix-apps` clears all of it - this part is identical on every
distro, since it's an Electron/Chromium convention, not a packaging one.

Self-updating apps like Discord are a separate problem: every update
unpacks a fresh `chrome-sandbox` binary into a new `app-<version>/` dir,
owned by your user instead of root. Chromium refuses to start with a
`FATAL sandbox... aborting now` error unless that binary is root-owned
and setuid (mode `4755`) - it won't just fall back to running unsandboxed.
`respin fix-apps` searches your whole home directory plus `/opt` (the two
most common places a Linux app ends up, whether that's a VM, a container,
or bare metal) for any `chrome-sandbox` binaries and fixes their
ownership/permissions via `sudo`, so this doesn't have to be done by hand
after every Discord update.

If an app is installed somewhere outside those defaults - a portable
install under a custom directory, something on a second drive, etc. -
register it with `respin add-search-path <dir>` (or the GUI's **Add app
install location...** button, which opens a folder picker) and `fix-apps`
will search it too from then on. `respin list-search-paths` shows what's
currently registered.

## GUI

`respin-gui` (launched from the application menu as **ReSpin**, or run
directly) is the primary way to use this. It's a thin front-end over
`respin.sh` - same backup/reinstall/fix-apps logic, one source of truth,
just with buttons and a live output panel instead of a terminal. The
subtitle shows which package manager it detected.

The app icon (`respin.png`) is installed to the standard hicolor icon
theme location and `/usr/share/pixmaps`, so it shows up in the application
menu and window switcher via the `.desktop` entry; `respin-gui` also loads
it directly for its own window/taskbar icon (checking the repo directory
first, then the installed locations, so it works whether you're running
from a checkout or the installed package).

- **Backup now** / **Fix broken apps** - run immediately, streamed to the log panel.
- **Search packages...** - a two-pane picker over every package available
  through the detected package manager (replaces the old terminal `fzf`
  flow): filter on the left, multi-select, "Add selected →" queues them into
  `~/.respin/extra-packages.txt` for the next reinstall; the right pane
  shows what's already queued, with a remove button. A red **Install queued
  packages now** button installs the queue immediately instead of waiting
  for a full reinstall - the queue clears automatically once they're
  installed (they're just normal packages after that, so the next backup
  picks them up on its own).
- **Install Flatpak + Flathub** - runs `flatpak-setup` and pops a reminder
  to log out and back in once it's done.
- **Configure npm-global PATH...** - opens a dialog listing the supported
  shells (bash/zsh/fish), pre-checking whichever are installed but not yet
  configured; Apply adds `~/.npm-global/bin` to `PATH` in each chosen
  shell's rc file so globally-installed `npm` packages are runnable without
  `sudo`.
- **Set up hourly auto-update** - runs `auto-update-setup` (see below):
  installs the hourly system-update cron job and fixes the container's cron
  daemon if it isn't actually running.
- **Add app install location...** - opens a folder picker; the chosen
  directory gets registered via `add-search-path` and is searched by
  `fix-apps` from then on, for apps installed outside the defaults
  (your home directory and `/opt`).
- **Reinstall from backup...** - opens a dialog listing every snapshot under
  `~/.respin/backups/`, pick one and confirm.

## CLI

The underlying script also works standalone (useful over SSH, or for
scripting):

```bash
respin backup                 # Snapshot installed packages + configs
respin reinstall [backup_dir] # Update system, reinstall from a backup (default: latest)
respin list-backups           # Show available backups
respin search                 # fzf-based package search, queue extras
respin install-extras         # Install the queued packages right now (doesn't wait for a reinstall)
respin flatpak-setup          # Install Flatpak + add the Flathub remote, then prompt to log out/in
respin npm-path-setup [shell...] # Add ~/.npm-global/bin to PATH (bash/zsh/fish); prompts if no shell given
respin list-shells            # Show supported shells + installed/configured state (used by the GUI)
respin auto-update-setup      # Install/repair the hourly unattended system-update cron job
respin fix-apps               # Just clear the caches/locks blocking apps from opening
respin add-search-path <dir>  # Register an extra directory for fix-apps' chrome-sandbox search
respin list-search-paths      # Show registered extra app-install directories
respin pkg-manager            # Print the detected package manager (pacman/apt/dnf/zypper/apk/xbps) and exit
respin list-packages          # Print every available package name (used by the GUI search)
respin                        # Interactive menu - full-screen TUI if dialog/whiptail is
                                 # installed, otherwise a coloured text menu
```

Backups are stored under `~/.respin/backups/<timestamp>/` (which is
`/config/.respin/...` inside the webtop container - on the bind-mounted
`./config` volume, so it survives a full container rebuild) and symlinked
as `~/.respin/latest`.

The interactive menu (`respin` with no arguments) auto-detects `dialog`,
falling back to `whiptail`, and finally to a coloured plain-text menu if
neither is installed. `reinstall` from the menu lets you pick *which* backup
to rebuild from via `list-backups` instead of always using the latest one.
Any action that needs `sudo` (`reinstall`, `flatpak-setup`) prompts once
up-front and keeps the credentials alive for the duration, instead of
prompting repeatedly mid-run.

### `list-backups`

Prints every snapshot under `~/.respin/backups/`, with native/flatpak
package counts and a `(latest)` marker on the one `~/.respin/latest`
points to. Used by the interactive menu to build the "pick a backup to
rebuild from" list for `reinstall`.

### `npm-path-setup`

Adds `export PATH="$HOME/.npm-global/bin:$PATH"` (fish gets the equivalent
`set -gx PATH ...` syntax) to the rc file of whichever shell(s) you pick, so
packages from `npm install -g` are runnable without `sudo`. Supports the
three shells most people actually use day to day - `bash`, `zsh`, `fish` -
and is idempotent (re-running it skips a shell that's already configured).

- `respin npm-path-setup zsh fish` - configure specific shells directly,
  no prompt (used by the GUI, and handy for scripting/SSH).
- `respin npm-path-setup` with no arguments detects which of the three
  shells are actually installed and asks: with `dialog`/`whiptail` it's a
  checklist pre-checked with the detected-but-unconfigured ones; in a plain
  terminal it's a yes/no prompt with a fallback to typing shell names
  manually. Nothing is changed until you're asked which shell to open in a
  new terminal (or run `exec $SHELL`) to pick it up - restarting the shell
  is not done automatically.

### `list-shells`

Prints one line per supported shell as `<shell>\t<installed>\t<configured>`
(`yes`/`no`) - e.g. `zsh	yes	no`. Used by the GUI's "Configure npm-global
PATH..." dialog and the interactive menu to pre-check the right boxes.

### `search`

Interactive `fzf` picker over every package available through the detected
package manager, with a live package-info preview (`pacman -Si` / `apt-cache
show` / `dnf info` / `zypper info` / `apk info` / `xbps-query -R`, whichever
applies). Tab to multi-select, Enter to confirm - picks are queued in
`~/.respin/extra-packages.txt` and get installed alongside the snapshotted
package list on the next `respin reinstall`.

### `install-extras`

Installs whatever is currently queued in `~/.respin/extra-packages.txt`
right away, in one batched, idempotent install transaction (falls back to
installing one-by-one if the batch fails, to isolate the broken package). On
full success the queue file is cleared, since those packages are now part of
the normal installed set and the next `respin backup` will capture them
without any help. Packages that fail to install are left queued for retry.

### `reinstall`

1. Updates the system (`pacman -Syu` / `apt-get update && upgrade` / `dnf
   upgrade` / `zypper refresh && update` / `apk update && upgrade` /
   `xbps-install -Suy`; enables pacman's `ParallelDownloads` first if it's off).
2. Bootstraps build tools (`base-devel` / `build-essential` / `gcc gcc-c++
   make` / `build-base`, per distro) plus `git`, `curl`.
3. Installs the snapshotted native + queued extra packages in one batched
   transaction (falls back to installing one-by-one only if the batch fails,
   to isolate which package broke it).
4. On Arch only: bootstraps `yay` if needed and installs any AUR/foreign
   packages from the snapshot. No-op everywhere else.
5. Installs Flatpak + Flathub (see above) and reinstalls snapshotted Flatpak apps.
6. Restores backed-up configs/dotfiles.
7. If zsh is present (freshly installed or already there), reinstalls
   Oh My Zsh + Powerlevel10k, restoring `.p10k.zsh` if present - skipped
   entirely on a bash/fish-only box, since zsh never got installed for it.
8. Runs the same cache/lock cleanup as `fix-apps`.
9. Runs `auto-update-setup` (see below) so the hourly update job comes back
   on its own - no manual step needed after a rebuild.

### `auto-update-setup`

Writes `~/scripts/auto-update.sh` (a tiny script that runs the correct
update command for whatever package manager ReSpin detected, logging to
`~/logs/auto-update.log`) and installs an hourly cron entry for it. Re-run
is idempotent - it won't duplicate the cron line or clobber unrelated jobs
already in the crontab.

It also works around a container-image issue that has nothing to do with
this specific job: the webtop image's supervised cron service starts
busybox's `crond`, which looks for jobs in `/var/spool/cron/crontabs/` by
default, but the `crontab` command actually installed (cronie's) writes to
the flat `/var/spool/cron/<user>` layout instead. Without a fix, `crond`
crashes on every boot and *no* cron job - this one or any other - ever
runs. `auto-update-setup` symlinks around the mismatch and restarts the
cron service, so it doubles as a general "make cron actually work in this
container" fix. Since it's a root-filesystem fix rather than a `$HOME`
one, it doesn't survive a full container rebuild by itself, which is why
`reinstall` calls it automatically instead of relying on it being set once
and forgotten.

## Install

ReSpin is meant to be handed to anyone running a Webtop container,
regardless of which distro image they're on - `install.sh` auto-detects the
package manager (pacman/apt/dnf/zypper/apk/xbps) and installs the CLI + GUI
accordingly.

### Any distro (Arch, Debian/Ubuntu, Fedora/RHEL, openSUSE, Alpine, Void)

```bash
git clone https://github.com/AdamBisCoding/ReSpin.git
cd ReSpin
./install.sh              # installs CLI + GUI (installs python3/Tk if missing)
./install.sh --no-gui     # CLI only, skips the GUI + its deps
```

Runs itself with `sudo` automatically if not already root. Installs to
`/usr/bin/respin`, `/usr/bin/respin-gui`, and adds a *ReSpin* entry to the
application menu - the exact same layout the Arch package below uses, so
behavior is identical either way. `sudo ./uninstall.sh` removes everything
it put down (backups and the auto-update cron job are left alone - see
`respin auto-update-setup` above for how to remove those).

`fzf` is optional (only used by the CLI's `respin search` - the GUI
picker doesn't need it) and gets installed automatically the first time
it's needed. `dialog`/`whiptail` are optional too - only used by the
interactive terminal menu (`respin` with no arguments) for the full-screen
TUI; without either it falls back to a coloured plain-text prompt.

### Arch (as a package, alternative to install.sh)

```bash
sudo pacman -S --needed base-devel
makepkg -si
```

Same install locations as `install.sh`, but tracked by pacman - gives you
`pacman -R respin` for a clean removal and `pacman -Qkk respin` to check
for tampered files, at the cost of only working on Arch.

### Debian/Ubuntu (.deb) and Fedora/RHEL (.rpm)

Prebuilt `.deb` and `.rpm` packages are attached to each
[GitHub release](https://github.com/AdamBisCoding/ReSpin/releases). Same
install locations as `install.sh`:

```bash
sudo apt install ./respin_<version>-1_all.deb      # Debian/Ubuntu
sudo dnf install ./respin-<version>-1.noarch.rpm    # Fedora/RHEL
```

A `.tar.gz` source release is attached too - same contents as a git
checkout, so `tar xf respin-<version>.tar.gz && cd respin-<version> &&
./install.sh` works the same as cloning the repo.

To build these yourself instead of using a release (needs `dpkg` and
`rpm-tools` on Arch, or the Debian/RHEL equivalents elsewhere):

```bash
packaging/build-release.sh          # defaults to pkgver from PKGBUILD
packaging/build-release.sh 1.2.3    # or pass a version explicitly
```

Artifacts land in `dist/` (gitignored, same as `pkg/` from `makepkg`).

## Contributing

This is still early, and there are more features planned. It's fully
open source, so if you've got ideas, run into a bug, or just want to
make it better - open an issue or a PR. All suggestions and
contributions are welcome.

## AI disclosure

I used AI in the creation of ReSpin, while I know that there are many people who are against the use of AI, I can absolutely understand why you wouldn't want to support the project. But I held the opinion that I would rather ship something that I think could help people, rather than worrying about LLM usage. For reference, I did review the code before shipping. I would rather be honest about the use of LLMs rather than be called out about it later. Have a great day, AdamB
