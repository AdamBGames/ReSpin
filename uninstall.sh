#!/usr/bin/env bash
#
# uninstall.sh - removes everything install.sh puts down. Arch users who
# installed via the PKGBUILD should use `sudo pacman -R respin` instead, so
# pacman's file database stays accurate.
#
# Does not touch ~/.respin (backups, extra-packages queue) or the hourly
# auto-update cron job/script - remove those separately if you want them
# gone too, since they hold state you might still want.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

FILES=(
  /usr/bin/respin
  /usr/bin/respin-gui
  /usr/lib/respin/respin_gui.py
  /usr/lib/respin/respin.png
  /usr/share/applications/respin.desktop
  /usr/share/icons/hicolor/512x512/apps/respin.png
  /usr/share/pixmaps/respin.png
)

for f in "${FILES[@]}"; do
  if [ -e "$f" ]; then
    rm -f "$f"
    echo "removed: $f"
  fi
done
rmdir /usr/lib/respin 2>/dev/null || true

echo ""
echo "ReSpin uninstalled. Backups and the auto-update cron job (if set up) were left in place -"
echo "see ~/.respin, ~/scripts/auto-update.sh, and your crontab if you want to remove those too."
