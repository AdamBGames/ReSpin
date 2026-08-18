#!/usr/bin/env bash
#
# install.sh — universal installer for ReSpin.
#
# Arch users can use the PKGBUILD instead (`makepkg -si`) for a real pacman
# package with dependency tracking and clean removal via `pacman -R`. This
# script is for everyone else — Debian/Ubuntu, Fedora/RHEL, openSUSE, Alpine,
# Void — and works on Arch too, just without pacman managing the files.
#
# Usage:
#   ./install.sh              Install CLI + GUI
#   ./install.sh --no-gui     Install the CLI only (skips python3/Tk deps)
#   sudo ./install.sh         Also fine — it re-execs itself with sudo either way
#
# Installs to the same paths the PKGBUILD uses, so behavior is identical
# regardless of which install method was used:
#   /usr/bin/respin, /usr/bin/respin-gui, /usr/lib/respin/*,
#   /usr/share/applications/respin.desktop, icon under hicolor + pixmaps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

NO_GUI=0
for arg in "$@"; do
  [ "$arg" = "--no-gui" ] && NO_GUI=1
done

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

if [ "$PKG_MANAGER" = "unknown" ]; then
  echo "No supported package manager found (looked for pacman, apt-get, dnf, zypper, apk, xbps-install)." >&2
  echo "ReSpin supports Arch/Manjaro/EndeavourOS/CachyOS, Debian/Ubuntu/Mint/Pop!_OS," >&2
  echo "Fedora/RHEL/Rocky/Alma/Nobara, openSUSE, Alpine, and Void." >&2
  exit 1
fi
echo "Detected package manager: $PKG_MANAGER"

for f in respin.sh respin_gui.py respin-gui respin.desktop respin.png; do
  if [ ! -f "$SCRIPT_DIR/$f" ]; then
    echo "Missing '$f' next to install.sh — run this from inside the ReSpin checkout." >&2
    exit 1
  fi
done

install_gui_deps() {
  echo "Installing GUI dependencies (python3 + Tk)..."
  case "$PKG_MANAGER" in
    pacman) pacman -S --noconfirm --needed python tk ;;
    apt)    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install python3-tk ;;
    dnf)    dnf -y install python3-tkinter ;;
    zypper) zypper --non-interactive install python3-tk ;;
    apk)    apk add python3 py3-tkinter ;;
    xbps)   xbps-install -Sy python3-tkinter ;;
  esac
}

echo "Installing ReSpin (CLI)..."
install -Dm755 "$SCRIPT_DIR/respin.sh" /usr/bin/respin

if [ "$NO_GUI" -eq 0 ]; then
  install_gui_deps
  echo "Installing ReSpin (GUI)..."
  install -Dm755 "$SCRIPT_DIR/respin_gui.py" /usr/lib/respin/respin_gui.py
  install -Dm755 "$SCRIPT_DIR/respin-gui" /usr/bin/respin-gui
  install -Dm644 "$SCRIPT_DIR/respin.desktop" /usr/share/applications/respin.desktop
  install -Dm644 "$SCRIPT_DIR/respin.png" /usr/share/icons/hicolor/512x512/apps/respin.png
  install -Dm644 "$SCRIPT_DIR/respin.png" /usr/share/pixmaps/respin.png
  install -Dm644 "$SCRIPT_DIR/respin.png" /usr/lib/respin/respin.png
  echo "Installed: respin, respin-gui"
else
  echo "Installed: respin (GUI skipped, --no-gui)"
fi

echo ""
echo "Run 'respin' for the interactive menu, or 'respin --help' for the full command list."
[ "$NO_GUI" -eq 0 ] && echo "Launch the GUI with 'respin-gui', or find 'ReSpin' in the application menu."
