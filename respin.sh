#!/usr/bin/env bash
#
# respin.sh — Respin (v2)
#
# Backup + rebuild tool for Arch/Manjaro/EndeavourOS/CachyOS (pacman),
# Debian/Ubuntu/Mint/Pop!_OS (apt), Fedora/RHEL/Rocky/Alma/Nobara (dnf),
# openSUSE (zypper), Alpine (apk), and Void (xbps) — plus a one-shot fix for
# Chromium/Electron/QtWebEngine apps (Falkon, Discord, VS Code, ...) that
# silently refuse to open due to stale singleton locks or corrupted caches.
#
# v2 changes:
#   * dialog/whiptail TUI (auto-detected, falls back to a coloured text menu)
#   * removed the setup_openclaw() curl-pipe-to-shell block (security risk,
#     was never called anyway)
#   * blank lines / comments filtered out of package lists before install
#     (a stray empty line used to abort the whole pacman transaction)
#   * extras queue + backup extras are now deduped before install
#   * apk: dropped the version-fragile --no-interactive flag (non-interactive
#     is apk's default anyway)
#   * chsh guarded (not present on minimal Alpine without the shadow pkg)
#   * one sudo prompt up-front with a keep-alive, instead of prompts
#     scattered through a 20-minute reinstall
#   * "reinstall" can now pick WHICH backup from a menu (list-backups added)
#   * warns before clearing caches if the target app is currently running
#   * added dnf (Fedora/RHEL family), zypper (openSUSE), and xbps (Void)
#     package-manager support alongside pacman/apt/apk
#   * .profile/.bash_profile/.zprofile now backed up too, so the login-shell
#     rc file Alpine's default ash actually reads isn't silently dropped
#   * auto-update-setup: hourly unattended system-update cron job, regenerated
#     on every reinstall (also fixes busybox crond vs. cronie's spool-path
#     mismatch, which otherwise leaves cron silently never running at all)
#
# Usage:
#   respin backup                 Snapshot installed packages + configs
#   respin reinstall [backup_dir] Update system, reinstall from a backup (default: latest)
#   respin list-backups           Show available backups
#   respin search                 Fuzzy-search all available packages,
#                                    queue extras for the next reinstall
#   respin install-extras         Install the queued packages right now
#   respin flatpak-setup          Install Flatpak + add the Flathub remote
#   respin npm-path-setup [shell...] Add ~/.npm-global/bin to PATH (bash/zsh/fish)
#   respin list-shells             Show supported shells + installed/configured state
#   respin auto-update-setup      Install hourly unattended system-update cron job
#   respin fix-apps               Clear caches/locks + fix chrome-sandbox perms (Falkon/Discord/etc)
#   respin                        Interactive menu (TUI if dialog/whiptail present)
#
# Run as your normal user (NOT root/sudo) — it calls sudo itself where needed.

set -uo pipefail

USER="${USER:-$(id -un)}"
export USER

RESPIN_HOME="$HOME/.respin"
BACKUP_ROOT="$RESPIN_HOME/backups"
LATEST_LINK="$RESPIN_HOME/latest"
EXTRA_PACKAGES_FILE="$RESPIN_HOME/extra-packages.txt"

# Hourly unattended-update script + its cron entry. Both live under $HOME
# (the bind-mounted config volume), so the files themselves already survive
# a full container rebuild — what doesn't survive is the cron *daemon*
# actually picking them up, which setup_auto_update/fix_crond_spool_path
# below take care of.
AUTO_UPDATE_SCRIPT="$HOME/scripts/auto-update.sh"
AUTO_UPDATE_LOG="$HOME/logs/auto-update.log"
AUTO_UPDATE_CRONTAB="$HOME/crontabs/$USER"
AUTO_UPDATE_CRON_LINE="0 * * * * $AUTO_UPDATE_SCRIPT"

# Dotfiles + config dirs worth preserving across a rebuild. Extend this list
# as new apps get added to the webtop image.
CONFIG_PATHS=(
  ".config/fish" ".config/kitty" ".config/htop" ".config/btop" ".config/geany"
  ".config/zathura" ".config/ranger" ".config/fastfetch" ".config/nvim"
  ".config/discord" ".config/konsolerc" ".config/konsole" ".config/falkon"
  ".config/Code" ".config/starship.toml" ".config/direnv" ".config/lazygit"
  ".config/fzf" ".config/flatpak" ".tmux.conf" ".config/tmux" ".gitconfig"
  ".ssh" ".config/dolphinrc" ".config/gwenviewrc" ".config/okularrc"
  ".config/spectaclerc" ".config/flameshot" ".config/filelight"
  ".config/kcalcrc" ".config/GIMP" ".config/inkscape" ".mozilla"
  ".thunderbird" ".config/transmission-daemon" ".config/keepassxc"
  ".config/obs-studio" ".config/audacity"
)

# Shells supported by `npm-path-setup` — the main ones people actually use
# interactively. Extend this (plus shell_rc_file/shell_path_line below) to
# add more.
SUPPORTED_SHELLS=(bash zsh fish)

# ---------------------------------------------------------------------------
# Pretty output helpers (plain-terminal path)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_HEAD=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m';  C_DIM=$'\033[2m';   C_OFF=$'\033[0m'
else
  C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi
head_() { printf '%s\n' "${C_HEAD}=== $* ===${C_OFF}"; }
ok_()   { printf '%s\n' "${C_OK}  ✔${C_OFF} $*"; }
warn_() { printf '%s\n' "${C_WARN}  ⚠ $*${C_OFF}"; }
err_()  { printf '%s\n' "${C_ERR}  ✘ $*${C_OFF}" >&2; }

usage() {
  cat <<'EOF'
Respin — backup / rebuild / app-fixer
(Arch, Debian/Ubuntu, Fedora/RHEL, openSUSE, Alpine, Void)

Usage:
  respin backup                 Snapshot installed packages + configs
  respin reinstall [backup_dir] Update system + reinstall from a backup (default: latest)
  respin list-backups           Show available backups
  respin search                 Fuzzy-search available packages to add
  respin install-extras         Install the queued packages right now
  respin flatpak-setup          Install Flatpak + add the Flathub remote
  respin npm-path-setup [shell...] Add ~/.npm-global/bin to PATH (bash/zsh/fish);
                                   with no arguments, asks interactively
  respin list-shells            Show supported shells + installed/configured state
  respin auto-update-setup      Install/repair the hourly unattended system-update cron job
  respin fix-apps               Clear caches/locks + fix chrome-sandbox perms (Falkon/Discord/etc)
  respin pkg-manager            Print the detected package manager and exit
  respin list-packages          Print every available package name (used by search UIs)
  respin                        Interactive menu (TUI when dialog/whiptail is installed)

Run as your normal user — sudo is invoked internally where needed.
EOF
}

# ---------------------------------------------------------------------------
# sudo up-front + keep-alive, so long reinstalls don't stall on re-prompts
# ---------------------------------------------------------------------------
SUDO_KEEPALIVE_PID=""
ensure_sudo() {
  [ "$(id -u)" -eq 0 ] && { err_ "Run Respin as your normal user, not root."; exit 1; }
  [ -n "$SUDO_KEEPALIVE_PID" ] && return 0
  sudo -v || { err_ "sudo authentication failed."; exit 1; }
  ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
}
cleanup() { [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Package manager abstraction — everything distro-specific lives here.
# ---------------------------------------------------------------------------
detect_pkg_manager() {
  if command -v pacman >/dev/null 2>&1; then echo "pacman"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v zypper >/dev/null 2>&1; then echo "zypper"
  elif command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v xbps-install >/dev/null 2>&1; then echo "xbps"
  else echo "unknown"
  fi
}
PKG_MANAGER="$(detect_pkg_manager)"

require_pkg_manager() {
  if [ "$PKG_MANAGER" = "unknown" ]; then
    err_ "no supported package manager found (looked for pacman, apt-get, dnf, zypper, apk, xbps-install)."
    err_ "Respin currently supports Arch/Manjaro/EndeavourOS/CachyOS, Debian/Ubuntu/Mint/Pop!_OS,"
    err_ "Fedora/RHEL/Rocky/Alma/Nobara, openSUSE, Alpine, and Void."
    exit 1
  fi
}

# Parallel downloads are the biggest win when reinstalling a large package
# set. pacman-only; apt/apk have no clean universal equivalent.
optimize_pacman() {
  if grep -q '^#ParallelDownloads' /etc/pacman.conf 2>/dev/null; then
    sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    ok_ "enabled ParallelDownloads in pacman.conf"
  fi
}

pkg_update_system() {
  case "$PKG_MANAGER" in
    pacman) optimize_pacman; sudo pacman -Syu --noconfirm ;;
    apt)    sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade ;;
    dnf)    sudo dnf -y upgrade ;;
    zypper) sudo zypper --non-interactive refresh && sudo zypper --non-interactive update ;;
    apk)    sudo apk update && sudo apk upgrade ;;
    xbps)   sudo xbps-install -Suy ;;
  esac
}

# Batched, idempotent install of "$@" — skips anything already installed.
pkg_install() {
  [ "$#" -eq 0 ] && return 0
  case "$PKG_MANAGER" in
    pacman) sudo pacman -S --noconfirm --needed "$@" ;;
    apt)    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "$@" ;;
    dnf)    sudo dnf -y install "$@" ;;
    zypper) sudo zypper --non-interactive install "$@" ;;
    apk)    sudo apk add "$@" ;;   # non-interactive is apk's default
    xbps)   sudo xbps-install -y "$@" ;;
  esac
}

pkg_is_installed() {
  case "$PKG_MANAGER" in
    pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
    apt)    dpkg -s "$1" >/dev/null 2>&1 ;;
    dnf)    rpm -q "$1" >/dev/null 2>&1 ;;
    zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    apk)    apk info -e "$1" >/dev/null 2>&1 ;;
    xbps)   xbps-query "$1" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

pkg_bootstrap_build_tools() {
  case "$PKG_MANAGER" in
    pacman) pkg_install git curl base-devel ;;
    apt)    pkg_install git curl build-essential ;;
    dnf)    pkg_install git curl gcc gcc-c++ make ;;
    zypper) pkg_install git curl gcc gcc-c++ make ;;
    apk)    pkg_install git curl build-base ;;
    xbps)   pkg_install git curl base-devel ;;
  esac
}

# Explicitly user-requested packages, one per line.
pkg_list_explicit() {
  case "$PKG_MANAGER" in
    pacman) pacman -Qqe ;;
    apt)    apt-mark showmanual ;;
    dnf)    dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null ;;
    # zypper has no manual-vs-dependency distinction like apt/dnf, so this
    # captures everything installed — a slightly larger snapshot than the
    # other package managers produce, but harmless on reinstall.
    zypper) rpm -qa --qf '%{NAME}\n' ;;
    apk)    sed -e 's/[<>=~].*//' -e '/^\s*$/d' /etc/apk/world 2>/dev/null ;;
    xbps)   xbps-query -m ;;
  esac
}

# Arch/AUR-only concept — empty elsewhere, the AUR step just no-ops.
pkg_list_foreign() {
  case "$PKG_MANAGER" in
    pacman) pacman -Qqem ;;
    *) : ;;
  esac
}

pkg_search_all() {
  case "$PKG_MANAGER" in
    pacman) pacman -Slq ;;
    apt)    apt-cache pkgnames ;;
    dnf)    dnf -q repoquery --qf '%{name}\n' --available 2>/dev/null | sort -u ;;
    # zypper has no plain "list all package names" command — parse the name
    # column out of its pipe-delimited package table instead.
    zypper) zypper --quiet packages | awk -F'|' 'NR>2 { gsub(/^ +| +$/, "", $3); if ($3 != "") print $3 }' | sort -u ;;
    apk)    apk search -q ;;
    # xbps-query prints "[*] name-version_rev  description"; strip the
    # trailing -version_rev segment to get the bare package name.
    xbps)   xbps-query -Rs '' 2>/dev/null | awk '{print $2}' | sed -E 's/-[^-]+$//' | sort -u ;;
  esac
}

pkg_preview_cmd() {
  case "$PKG_MANAGER" in
    pacman) echo 'pacman -Si {1} 2>/dev/null' ;;
    apt)    echo 'apt-cache show {1} 2>/dev/null' ;;
    dnf)    echo 'dnf info {1} 2>/dev/null' ;;
    zypper) echo 'zypper info {1} 2>/dev/null' ;;
    apk)    echo 'apk info {1} 2>/dev/null' ;;
    xbps)   echo 'xbps-query -R {1} 2>/dev/null' ;;
  esac
}

# Read a package-list file into the named array, dropping blank lines,
# comments and surrounding whitespace. (A single empty line used to abort
# a whole batched pacman transaction.)
read_pkg_file() {
  local -n _arr="$1"
  _arr=()
  [ -f "$2" ] || return 0
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ""|\#*) continue ;; esac
    _arr+=("$line")
  done < "$2"
}

dedupe_array() {
  local -n _arr="$1"
  [ "${#_arr[@]}" -gt 0 ] || return 0
  mapfile -t _arr < <(printf '%s\n' "${_arr[@]}" | sort -u)
}

ensure_aur_helper() {
  [ "$PKG_MANAGER" = "pacman" ] || return 0
  command -v yay >/dev/null 2>&1 && return 0
  head_ "No AUR helper found — bootstrapping yay"
  local tmp; tmp=$(mktemp -d)
  if git clone --depth=1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" \
      && (cd "$tmp/yay-bin" && makepkg -si --noconfirm); then
    ok_ "yay installed."
  else
    warn_ "failed to bootstrap yay — AUR/foreign packages will be skipped."
  fi
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Cache/lock cleanup — fixes the "app just doesn't open" problem
# ---------------------------------------------------------------------------
clear_broken_app_caches() {
  head_ "Clearing Chromium/Electron/QtWebEngine caches & stale locks"

  # Deleting caches out from under a RUNNING app can corrupt its profile —
  # warn rather than silently doing it.
  local proc
  for proc in discord Discord falkon code electron; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
      warn_ "'$proc' appears to be running — close it first for a clean fix."
    fi
  done

  # Stale SingletonLock/Socket/Cookie files make Electron apps think another
  # instance owns them; they signal a dead socket and exit without a window.
  find "$HOME/.config" -maxdepth 2 -type f -name 'Singleton*' -print -delete 2>/dev/null
  find "$HOME/.config" -maxdepth 2 -type l -name 'Singleton*' -print -delete 2>/dev/null

  local electron_dirs=(
    "$HOME/.config/discord"
    "$HOME/.config/Code"
    "$HOME/.config/Code - OSS"
  )
  local cache_subdirs=(Cache "Code Cache" GPUCache "Service Worker" blob_storage Crashpad DawnCache "Shared Dictionary Cache")
  local dir sub
  for dir in "${electron_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for sub in "${cache_subdirs[@]}"; do
      [ -d "$dir/$sub" ] || continue
      rm -rf "${dir:?}/${sub:?}"
      ok_ "cleared: $dir/$sub"
    done
  done

  # Falkon / QtWebEngine
  for dir in "$HOME/.cache/falkon" "$HOME/.cache/QtWebEngine" "$HOME/.cache/qtwebengine"; do
    [ -d "$dir" ] || continue
    rm -rf "${dir:?}"
    ok_ "cleared: $dir"
  done

  # Corrupted GPU shader caches cause blank/crashing windows on
  # software-rendered containerised desktops.
  rm -rf "$HOME/.cache/mesa_shader_cache" "$HOME/.cache/mesa_shader_cache_db" 2>/dev/null

  fix_chrome_sandbox

  echo "Done — try opening the app again."
}

# Self-updating Electron apps (Discord et al.) unpack a fresh chrome-sandbox
# binary into a new app-<version>/ dir on every update, owned by the user
# instead of root. Chromium refuses to start without it being root-owned
# and setuid (mode 4755), and aborts with a FATAL sandbox error instead of
# just disabling the sandbox — so this needs fixing again after every
# Discord update, not just once.
fix_chrome_sandbox() {
  local sandbox_bins=() f owner mode fixed_any=0
  while IFS= read -r -d '' f; do
    sandbox_bins+=("$f")
  done < <(find "$HOME/.config" -maxdepth 3 -type f -name 'chrome-sandbox' -print0 2>/dev/null)

  for f in "${sandbox_bins[@]}"; do
    owner=$(stat -c '%U' "$f" 2>/dev/null)
    mode=$(stat -c '%a' "$f" 2>/dev/null)
    [ "$owner" = "root" ] && [ "$mode" = "4755" ] && continue

    if sudo chown root:root "$f" 2>/dev/null && sudo chmod 4755 "$f" 2>/dev/null; then
      ok_ "fixed sandbox permissions: $f"
      fixed_any=1
    else
      warn_ "couldn't fix sandbox permissions on $f (needs root) — run with sudo access available."
    fi
  done

  [ "$fixed_any" -eq 1 ] && ok_ "chrome-sandbox is now root-owned + setuid (4755) where needed."
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
do_backup() {
  require_pkg_manager
  local ts backup_dir
  ts=$(date +%Y%m%d-%H%M%S)
  backup_dir="$BACKUP_ROOT/$ts"
  mkdir -p "$backup_dir/config"

  head_ "Snapshotting installed packages ($PKG_MANAGER)"
  pkg_list_explicit > "$backup_dir/packages-native.txt"
  pkg_list_foreign  > "$backup_dir/packages-foreign.txt"
  if command -v flatpak >/dev/null 2>&1; then
    flatpak list --app --columns=application > "$backup_dir/flatpak-apps.txt" 2>/dev/null || : > "$backup_dir/flatpak-apps.txt"
  else
    : > "$backup_dir/flatpak-apps.txt"
  fi
  [ -f "$EXTRA_PACKAGES_FILE" ] && cp "$EXTRA_PACKAGES_FILE" "$backup_dir/packages-extra.txt"

  ok_ "native packages:  $(wc -l < "$backup_dir/packages-native.txt")"
  ok_ "foreign packages: $(wc -l < "$backup_dir/packages-foreign.txt")"
  ok_ "flatpak apps:     $(wc -l < "$backup_dir/flatpak-apps.txt")"

  head_ "Backing up configs & dotfiles"
  local f p dest
  # .profile is the one every POSIX-ish shell (dash, ash, ksh, and bash/zsh
  # as a fallback) reads as its login-shell rc — without it, Alpine's default
  # ash shell would silently lose its config on rebuild even though its
  # packages/configs are otherwise fully covered.
  for f in .zshrc .zprofile .p10k.zsh .zsh_history .bashrc .bash_profile .profile .gitconfig; do
    [ -e "$HOME/$f" ] && cp -a "$HOME/$f" "$backup_dir/config/" 2>/dev/null
  done
  for p in "${CONFIG_PATHS[@]}"; do
    [ -e "$HOME/$p" ] || continue
    dest="$backup_dir/config/$(dirname "$p")"
    mkdir -p "$dest"
    cp -a "$HOME/$p" "$dest/" 2>/dev/null && ok_ "backed up: $p"
  done

  ln -sfn "$backup_dir" "$LATEST_LINK"
  echo ""
  ok_ "Backup complete: $backup_dir"
  echo "${C_DIM}(linked as latest: $LATEST_LINK)${C_OFF}"
}

list_backups() {
  [ -d "$BACKUP_ROOT" ] || { echo "No backups yet."; return 0; }
  local d mark
  for d in "$BACKUP_ROOT"/*/; do
    [ -d "$d" ] || continue
    mark=""
    [ "$(readlink -f "$LATEST_LINK" 2>/dev/null)" = "$(readlink -f "$d")" ] && mark="  (latest)"
    printf '%s  native:%s  flatpak:%s%s\n' \
      "$(basename "$d")" \
      "$(wc -l < "$d/packages-native.txt" 2>/dev/null || echo '?')" \
      "$(wc -l < "$d/flatpak-apps.txt" 2>/dev/null || echo '?')" \
      "$mark"
  done
}

# ---------------------------------------------------------------------------
# Flatpak + Flathub — portable fallback on every distro
# ---------------------------------------------------------------------------
setup_flatpak() {
  head_ "Installing Flatpak + Flathub"
  if ! command -v flatpak >/dev/null 2>&1; then
    pkg_install flatpak || { warn_ "failed to install flatpak."; return 1; }
  fi

  # No system D-Bus in a stripped-down container → system-scope flatpak fails
  # with "Unable to connect to system bus". Try system, fall back to --user.
  local scope="" errlog
  errlog=$(mktemp)
  if flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>"$errlog"; then
    scope="system"
  elif flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
    scope="user"
  else
    warn_ "Flathub add failed at both system and user scope."
    warn_ "$(cat "$errlog" 2>/dev/null)"
  fi
  rm -f "$errlog"

  if [ "$scope" = "user" ]; then
    local rcfile
    for rcfile in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rcfile" ] || continue
      grep -q 'flatpak/exports/share' "$rcfile" 2>/dev/null || \
        echo 'export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:$XDG_DATA_DIRS"' >> "$rcfile"
    done
    export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:${XDG_DATA_DIRS:-}"
  fi
  ok_ "Flathub scope: ${scope:-none}"
  echo ""
  warn_ "Log out and log back in for Flatpak app-menu integration and portals to register."
}

# ---------------------------------------------------------------------------
# Hourly auto-update cron job
# ---------------------------------------------------------------------------
# LinuxServer webtop images supervise cron via busybox crond, which defaults
# to reading jobs from /var/spool/cron/crontabs/ — but the `crontab` binary
# actually installed is cronie's, which writes to the flat /var/spool/cron/
# layout instead. Whichever distro this ends up on, that mismatch means
# busybox crond crashes at boot and no cron job ever fires until this is
# patched. It's a root-filesystem fix, not a $HOME one, so it doesn't survive
# a container rebuild on its own and has to be reapplied — this function does
# that, and setup_auto_update calls it every time so a fresh container gets a
# working cron daemon as a side effect of just reinstalling the update job.
fix_crond_spool_path() {
  command -v crontab >/dev/null 2>&1 || return 0
  sudo mkdir -p /var/spool/cron/crontabs
  sudo ln -sf "/var/spool/cron/$USER" "/var/spool/cron/crontabs/$USER"
  if [ -e /run/service/svc-cron ] && command -v s6-svc >/dev/null 2>&1; then
    sudo s6-svc -t /run/service/svc-cron 2>/dev/null
  fi
  ok_ "crond spool path fixed (busybox crond vs. cronie mismatch) + service restarted"
}

# Regenerates the updater script fresh each time (rather than restoring it
# from a backup) so it always matches the update command for whichever
# package manager is actually detected on this box.
setup_auto_update() {
  require_pkg_manager
  head_ "Setting up hourly auto-update cron job"

  local update_cmd
  case "$PKG_MANAGER" in
    pacman) update_cmd='sudo pacman -Syu --noconfirm' ;;
    apt)    update_cmd='sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade' ;;
    dnf)    update_cmd='sudo dnf -y upgrade' ;;
    zypper) update_cmd='sudo zypper --non-interactive refresh && sudo zypper --non-interactive update' ;;
    apk)    update_cmd='sudo apk update && sudo apk upgrade' ;;
    xbps)   update_cmd='sudo xbps-install -Suy' ;;
  esac

  mkdir -p "$(dirname "$AUTO_UPDATE_SCRIPT")" "$(dirname "$AUTO_UPDATE_LOG")" "$(dirname "$AUTO_UPDATE_CRONTAB")"
  cat > "$AUTO_UPDATE_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
# auto-update.sh — full system update, run hourly via cron.
# Regenerated by 'respin reinstall' / 'respin auto-update-setup' — edits here
# get overwritten on the next respin, change the update command in
# setup_auto_update() in respin.sh instead.
LOG_FILE="$AUTO_UPDATE_LOG"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Starting update..." >> "\$LOG_FILE"
$update_cmd >> "\$LOG_FILE" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Update finished." >> "\$LOG_FILE"
SCRIPT
  chmod +x "$AUTO_UPDATE_SCRIPT"
  ok_ "wrote $AUTO_UPDATE_SCRIPT ($PKG_MANAGER)"

  touch "$AUTO_UPDATE_CRONTAB"
  grep -qF "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_CRONTAB" 2>/dev/null || echo "$AUTO_UPDATE_CRON_LINE" >> "$AUTO_UPDATE_CRONTAB"
  crontab "$AUTO_UPDATE_CRONTAB"
  ok_ "hourly cron job installed (logs: $AUTO_UPDATE_LOG)"

  fix_crond_spool_path
}

# ---------------------------------------------------------------------------
# npm-global PATH — so `npm install -g` packages are runnable without sudo
# ---------------------------------------------------------------------------
shell_is_supported() {
  local s
  for s in "${SUPPORTED_SHELLS[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

shell_rc_file() {
  case "$1" in
    bash) echo "$HOME/.bashrc" ;;
    zsh)  echo "$HOME/.zshrc" ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    return 1 ;;
  esac
}

# bash/zsh use `export`; fish has its own `set -gx` syntax for exported vars.
shell_path_line() {
  case "$1" in
    bash|zsh) echo 'export PATH="$HOME/.npm-global/bin:$PATH"' ;;
    fish)     echo 'set -gx PATH $HOME/.npm-global/bin $PATH' ;;
    *)        return 1 ;;
  esac
}

shell_is_configured() {
  local rc; rc=$(shell_rc_file "$1") || return 1
  [ -f "$rc" ] && grep -qF '.npm-global/bin' "$rc" 2>/dev/null
}

configure_shell_npm_path() {
  local shell="$1" rc line
  rc=$(shell_rc_file "$shell") || { warn_ "unsupported shell: $shell"; return 1; }
  line=$(shell_path_line "$shell") || return 1
  if shell_is_configured "$shell"; then
    ok_ "$shell already configured ($rc)"
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  printf '\n%s\n' "$line" >> "$rc"
  ok_ "added npm-global PATH to $rc"
}

# Used by `respin list-shells` and to pre-check the GUI/TUI shell pickers.
list_shells() {
  local s installed configured
  for s in "${SUPPORTED_SHELLS[@]}"; do
    command -v "$s" >/dev/null 2>&1 && installed=yes || installed=no
    shell_is_configured "$s" && configured=yes || configured=no
    printf '%s\t%s\t%s\n' "$s" "$installed" "$configured"
  done
}

do_npm_path_setup() {
  local -a chosen=()
  if [ "$#" -gt 0 ]; then
    local s
    for s in "$@"; do
      if shell_is_supported "$s"; then
        chosen+=("$s")
      else
        warn_ "unsupported shell: $s (supported: ${SUPPORTED_SHELLS[*]})"
      fi
    done
  else
    local -a installed=()
    mapfile -t installed < <(
      local s
      for s in "${SUPPORTED_SHELLS[@]}"; do command -v "$s" >/dev/null 2>&1 && echo "$s"; done
    )
    if [ "${#installed[@]}" -eq 0 ]; then
      warn_ "none of the supported shells (${SUPPORTED_SHELLS[*]}) were found on this system."
      return 0
    fi

    detect_dialog
    if [ -n "$DIALOG_BIN" ]; then
      local -a items=() s state desc
      for s in "${SUPPORTED_SHELLS[@]}"; do
        state="off"
        if shell_is_configured "$s"; then
          desc="already configured"
        elif printf '%s\n' "${installed[@]}" | grep -qx "$s"; then
          desc="detected, not yet configured"; state="on"
        else
          desc="not detected"
        fi
        items+=("$s" "$desc" "$state")
      done
      local picked
      picked=$("$DIALOG_BIN" --title "npm-global PATH" --checklist \
        "Add ~/.npm-global/bin to PATH for which shell(s)?" 15 70 6 \
        "${items[@]}" 3>&1 1>&2 2>&3) || return 0
      eval "chosen=($picked)"
    elif [ -t 0 ]; then
      echo "Detected shells: ${installed[*]}"
      local ans
      read -rp "Add npm-global PATH for the detected shell(s) above? [Y/n] " ans
      case "$ans" in
        n|N) read -rp "Which shell(s) instead? (space-separated, from: ${SUPPORTED_SHELLS[*]}): " -a chosen ;;
        *)   chosen=("${installed[@]}") ;;
      esac
    else
      err_ "not a terminal and no shells given — pass them explicitly: respin npm-path-setup <shell...>"
      return 1
    fi
  fi

  [ "${#chosen[@]}" -eq 0 ] && { echo "No shells selected."; return 0; }
  head_ "Configuring npm-global PATH"
  local s
  for s in "${chosen[@]}"; do configure_shell_npm_path "$s"; done
  echo ""
  echo "Open a new terminal (or run 'exec \$SHELL') to pick up the change."
}

# ---------------------------------------------------------------------------
# zsh / Oh My Zsh / Powerlevel10k
# ---------------------------------------------------------------------------
safe_chsh() {
  command -v chsh >/dev/null 2>&1 || { warn_ "chsh not available — set your shell manually to: $1"; return 0; }
  sudo chsh -s "$1" "$USER" 2>/dev/null || warn_ "chsh failed — set your shell manually to: $1"
}

setup_zsh() {
  local backup_dir="$1"
  command -v zsh >/dev/null 2>&1 || { warn_ "zsh not installed — skipping Oh My Zsh/p10k."; return 0; }

  head_ "Installing Oh My Zsh + Powerlevel10k"
  rm -rf "$HOME/.oh-my-zsh" "$HOME"/.oh-my-zsh-backup* 2>/dev/null
  rm -f "$HOME/.zshrc" "$HOME/.zshrc.pre-oh-my-zsh" "$HOME"/.zcompdump* 2>/dev/null

  safe_chsh "$(command -v bash)"   # avoid lockout mid-install
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

  local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  mkdir -p "$zsh_custom/themes"
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$zsh_custom/themes/powerlevel10k"
  [ -f "$HOME/.zshrc" ] && sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"

  if [ -f "$backup_dir/config/.p10k.zsh" ]; then
    cp -a "$backup_dir/config/.p10k.zsh" "$HOME/.p10k.zsh"
    ok_ "restored previous .p10k.zsh from backup."
  else
    warn_ "no previous .p10k.zsh in backup — run 'p10k configure' after first login."
  fi

  safe_chsh "$(command -v zsh)"
}

# ---------------------------------------------------------------------------
# Reinstall
# ---------------------------------------------------------------------------
do_reinstall() {
  require_pkg_manager
  ensure_sudo
  local backup_dir="${1:-$LATEST_LINK}"
  if [ ! -e "$backup_dir" ]; then
    err_ "no backup at '$backup_dir'. Run 'respin backup' on the instance you're replacing first."
    exit 1
  fi
  backup_dir=$(readlink -f "$backup_dir")
  head_ "Reinstalling from backup: $backup_dir ($PKG_MANAGER)"

  head_ "1. System update"
  pkg_update_system

  head_ "2. Bootstrap dependencies"
  pkg_bootstrap_build_tools

  local -a native_packages foreign_packages extra_packages queued
  read_pkg_file native_packages  "$backup_dir/packages-native.txt"
  read_pkg_file foreign_packages "$backup_dir/packages-foreign.txt"
  read_pkg_file extra_packages   "$backup_dir/packages-extra.txt"
  read_pkg_file queued           "$EXTRA_PACKAGES_FILE"
  extra_packages+=("${queued[@]:-}")
  # drop the possible empty element from the :- fallback, then dedupe
  local -a tmp=()
  local pkg
  for pkg in "${extra_packages[@]:-}"; do [ -n "$pkg" ] && tmp+=("$pkg"); done
  extra_packages=("${tmp[@]:-}")
  dedupe_array extra_packages

  head_ "3. Installing ${#native_packages[@]} native + ${#extra_packages[@]} extra packages"
  local -a failed_packages=() to_install=()
  to_install=("${native_packages[@]:-}" "${extra_packages[@]:-}")
  tmp=(); for pkg in "${to_install[@]:-}"; do [ -n "$pkg" ] && tmp+=("$pkg"); done
  to_install=("${tmp[@]:-}")
  if [ "${#to_install[@]}" -gt 0 ] && [ -n "${to_install[0]}" ]; then
    # One batched transaction resolves shared deps together — far faster
    # than package-by-package.
    if ! pkg_install "${to_install[@]}"; then
      warn_ "batch install hit a snag — retrying individually to isolate failures..."
      for pkg in "${to_install[@]}"; do
        pkg_is_installed "$pkg" && continue
        pkg_install "$pkg" || failed_packages+=("$pkg")
      done
    fi
  fi

  head_ "4. AUR / foreign packages (${#foreign_packages[@]})"
  local -a failed_aur=()
  if [ "${#foreign_packages[@]}" -gt 0 ]; then
    ensure_aur_helper
    if command -v yay >/dev/null 2>&1; then
      yay -S --noconfirm --needed "${foreign_packages[@]}" || failed_aur=("${foreign_packages[@]}")
    else
      failed_aur=("${foreign_packages[@]}")
    fi
  fi

  setup_flatpak
  if [ -s "$backup_dir/flatpak-apps.txt" ] && command -v flatpak >/dev/null 2>&1; then
    head_ "5. Reinstalling Flatpak apps"
    local app
    while IFS= read -r app; do
      [ -n "$app" ] && flatpak install -y --noninteractive flathub "$app"
    done < "$backup_dir/flatpak-apps.txt"
  fi

  head_ "6. Restoring configs"
  cp -a "$backup_dir/config/." "$HOME/" 2>/dev/null

  setup_zsh "$backup_dir"
  clear_broken_app_caches

  head_ "9. Hourly auto-update cron"
  setup_auto_update

  echo ""
  head_ "Done"
  if [ "${#failed_packages[@]}" -gt 0 ]; then
    warn_ "Native packages that failed:"
    printf '  - %s\n' "${failed_packages[@]}"
  fi
  if [ "${#failed_aur[@]}" -gt 0 ]; then
    warn_ "AUR/foreign packages that failed:"
    printf '  - %s\n' "${failed_aur[@]}"
  fi
  echo "Log out/in or run 'exec \$SHELL' to pick up any shell changes now."
}

# ---------------------------------------------------------------------------
# Search — browse all available packages and queue extras
# ---------------------------------------------------------------------------
do_search() {
  require_pkg_manager
  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not found — installing it (needed for interactive search)..."
    ensure_sudo
    pkg_install fzf || { err_ "couldn't install fzf."; return 1; }
  fi
  mkdir -p "$RESPIN_HOME"
  head_ "Search available packages ($PKG_MANAGER)"
  echo "${C_DIM}(Tab to multi-select, Enter to confirm, Esc to cancel)${C_OFF}"
  local picked preview
  preview="$(pkg_preview_cmd)"
  picked=$(pkg_search_all | fzf --multi ${preview:+--preview "$preview"} --prompt="add packages> ") || true
  if [ -z "$picked" ]; then
    echo "No packages selected."
    return 0
  fi
  printf '%s\n' "$picked" >> "$EXTRA_PACKAGES_FILE"
  sort -u -o "$EXTRA_PACKAGES_FILE" "$EXTRA_PACKAGES_FILE"
  local -a picked_arr
  mapfile -t picked_arr <<< "$picked"
  ok_ "Queued for the next reinstall:"
  printf '  + %s\n' "${picked_arr[@]}"
}

# ---------------------------------------------------------------------------
# Install the queued extras right now
# ---------------------------------------------------------------------------
do_install_extras() {
  require_pkg_manager
  local -a extra_packages
  read_pkg_file extra_packages "$EXTRA_PACKAGES_FILE"
  if [ "${#extra_packages[@]}" -eq 0 ]; then
    echo "No packages queued. Run 'respin search' (or Search packages in the menu) first."
    return 0
  fi

  ensure_sudo
  head_ "Installing ${#extra_packages[@]} queued package(s) ($PKG_MANAGER)"

  local -a failed=()
  local pkg
  if ! pkg_install "${extra_packages[@]}"; then
    warn_ "batch install hit a snag — retrying individually to isolate failures..."
    for pkg in "${extra_packages[@]}"; do
      pkg_is_installed "$pkg" && continue
      pkg_install "$pkg" || failed+=("$pkg")
    done
  fi

  if [ "${#failed[@]}" -eq 0 ]; then
    : > "$EXTRA_PACKAGES_FILE"
    ok_ "Installed. Queue cleared — these are now normal installed packages, so the next"
    echo "  'respin backup' captures them automatically without needing the extras queue."
  else
    printf '%s\n' "${failed[@]}" > "$EXTRA_PACKAGES_FILE"
    warn_ "Failed to install (left queued for retry):"
    printf '  - %s\n' "${failed[@]}"
  fi
}

# ---------------------------------------------------------------------------
# TUI (dialog / whiptail) with plain-text fallback
# ---------------------------------------------------------------------------
DIALOG_BIN=""
detect_dialog() {
  if command -v dialog >/dev/null 2>&1; then DIALOG_BIN="dialog"
  elif command -v whiptail >/dev/null 2>&1; then DIALOG_BIN="whiptail"
  fi
}

tui_msg() {  # tui_msg "title" "message"
  "$DIALOG_BIN" --title "$1" --msgbox "$2" 12 70
}

tui_yesno() { # tui_yesno "title" "question" -> 0 yes / 1 no
  "$DIALOG_BIN" --title "$1" --yesno "$2" 10 70
}

# Run a long action with output visible, then pause so the user can read it
# before the menu redraws over it.
run_visible() {
  clear
  "$@"
  echo ""
  read -rp "Press Enter to return to the menu..." _
}

tui_pick_backup() {
  local -a items=()
  local d name
  if [ -d "$BACKUP_ROOT" ]; then
    for d in "$BACKUP_ROOT"/*/; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      items+=("$name" "native:$(wc -l < "$d/packages-native.txt" 2>/dev/null || echo '?')  flatpak:$(wc -l < "$d/flatpak-apps.txt" 2>/dev/null || echo '?')")
    done
  fi
  if [ "${#items[@]}" -eq 0 ]; then
    tui_msg "Reinstall" "No backups found.\n\nRun a Backup first (on the instance you're replacing)."
    return 1
  fi
  local choice
  choice=$("$DIALOG_BIN" --title "Reinstall" --menu "Pick a backup to rebuild from:" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
  echo "$BACKUP_ROOT/$choice"
}

show_tui_menu() {
  local extras_count=0
  while true; do
    extras_count=0
    [ -s "$EXTRA_PACKAGES_FILE" ] && extras_count=$(grep -cve '^[[:space:]]*$' "$EXTRA_PACKAGES_FILE" 2>/dev/null || :)
    local choice
    choice=$("$DIALOG_BIN" --title "Respin — $USER ($PKG_MANAGER)" \
      --menu "What do you want to do?" 21 72 10 \
      1 "Backup current install" \
      2 "Reinstall / rebuild from a backup" \
      3 "Search packages to add (fuzzy, multi-select)" \
      4 "Install queued packages now ($extras_count queued)" \
      5 "List backups" \
      6 "Install Flatpak + Flathub" \
      7 "Configure npm-global PATH for your shell(s)" \
      8 "Install/repair hourly auto-update cron" \
      9 "Fix broken apps (clear caches/locks)" \
      10 "Help" \
      11 "Quit" 3>&1 1>&2 2>&3) || break
    case "$choice" in
      1) run_visible do_backup ;;
      2) local b; b=$(tui_pick_backup) || continue
         tui_yesno "Reinstall" "Rebuild this machine from:\n\n$b\n\nThis updates the system and installs the full package set. Continue?" \
           && run_visible do_reinstall "$b" ;;
      3) clear; do_search; read -rp "Press Enter to return to the menu..." _ ;;
      4) tui_yesno "Install extras" "Install the $extras_count queued package(s) now?" \
           && run_visible do_install_extras ;;
      5) run_visible list_backups ;;
      6) run_visible setup_flatpak ;;
      7) run_visible do_npm_path_setup ;;
      8) run_visible setup_auto_update ;;
      9) tui_yesno "Fix apps" "Close Discord / VS Code / Falkon first if they're open.\n\nClear caches and stale locks now?" \
           && run_visible clear_broken_app_caches ;;
      10) tui_msg "Help" "$(usage)" ;;
      11) break ;;
    esac
  done
  clear
}

show_text_menu() {
  while true; do
    echo ""
    echo "${C_HEAD}===================================${C_OFF}"
    echo "${C_HEAD}  Respin — $USER ($PKG_MANAGER)${C_OFF}"
    echo "${C_HEAD}===================================${C_OFF}"
    echo "  1) Backup current install"
    echo "  2) Reinstall / rebuild from latest backup"
    echo "  3) Search packages to add"
    echo "  4) Install queued packages now"
    echo "  5) List backups"
    echo "  6) Install Flatpak + Flathub"
    echo "  7) Configure npm-global PATH"
    echo "  8) Install/repair hourly auto-update cron"
    echo "  9) Fix broken apps (clear caches)"
    echo " 10) Quit"
    read -rp "Choose an option [1-10]: " choice
    case "$choice" in
      1) do_backup ;;
      2) do_reinstall ;;
      3) do_search ;;
      4) do_install_extras ;;
      5) list_backups ;;
      6) setup_flatpak ;;
      7) do_npm_path_setup ;;
      8) setup_auto_update ;;
      9) clear_broken_app_caches ;;
      10) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

show_menu() {
  detect_dialog
  if [ -n "$DIALOG_BIN" ]; then
    show_tui_menu
  else
    echo "${C_DIM}(tip: install 'dialog' for the full-screen menu — falling back to text)${C_OFF}"
    show_text_menu
  fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  mkdir -p "$RESPIN_HOME"
  case "${1:-}" in
    backup)         do_backup ;;
    reinstall)      do_reinstall "${2:-$LATEST_LINK}" ;;
    list-backups)   list_backups ;;
    search)         do_search ;;
    install-extras) do_install_extras ;;
    flatpak-setup)  ensure_sudo; setup_flatpak ;;
    npm-path-setup) shift; do_npm_path_setup "$@" ;;
    list-shells)    list_shells ;;
    auto-update-setup) setup_auto_update ;;
    fix-apps)       clear_broken_app_caches ;;
    pkg-manager)    echo "$PKG_MANAGER" ;;
    list-packages)  require_pkg_manager; pkg_search_all ;;
    -h|--help)      usage ;;
    "")             show_menu ;;
    *)              usage; exit 1 ;;
  esac
}

main "$@"