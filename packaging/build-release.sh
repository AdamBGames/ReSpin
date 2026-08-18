#!/usr/bin/env bash
#
# build-release.sh — builds .tar.gz, .deb, and .rpm release artifacts for
# Respin into dist/. The Arch package still comes from the PKGBUILD
# (`makepkg -si`) at the repo root — this script covers everyone else.
#
# Requires dpkg-deb (for .deb) and rpmbuild (for .rpm), on Arch:
#   sudo pacman -S dpkg rpm-tools
#
# Usage: packaging/build-release.sh [version]
#   version defaults to pkgver in PKGBUILD (currently the source of truth).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

VERSION="${1:-$(awk -F= '/^pkgver=/{print $2}' PKGBUILD)}"
DIST_DIR="$ROOT_DIR/dist"

echo "Building Respin $VERSION release artifacts into dist/"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

SRC_FILES=(respin.sh respin_gui.py respin-gui respin.desktop respin.png)
for f in "${SRC_FILES[@]}"; do
  [ -f "$ROOT_DIR/$f" ] || { echo "Missing $f — run from the Respin repo root." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# .tar.gz — source release: same files install.sh expects, so
# `tar xf respin-$VERSION.tar.gz && cd respin-$VERSION && ./install.sh` works
# on any of the six supported distros.
# ---------------------------------------------------------------------------
echo "==> Building tar.gz"
TAR_STAGE="$DIST_DIR/tar/respin-$VERSION"
mkdir -p "$TAR_STAGE"
cp "${SRC_FILES[@]}" install.sh uninstall.sh README.md "$TAR_STAGE/"
tar -C "$DIST_DIR/tar" -czf "$DIST_DIR/respin-$VERSION.tar.gz" "respin-$VERSION"
rm -rf "$DIST_DIR/tar"

# ---------------------------------------------------------------------------
# .deb
# ---------------------------------------------------------------------------
if command -v dpkg-deb >/dev/null 2>&1; then
  echo "==> Building .deb"
  DEB_STAGE="$DIST_DIR/deb-stage"
  rm -rf "$DEB_STAGE"
  mkdir -p "$DEB_STAGE/DEBIAN"
  install -Dm755 respin.sh "$DEB_STAGE/usr/bin/respin"
  install -Dm755 respin_gui.py "$DEB_STAGE/usr/lib/respin/respin_gui.py"
  install -Dm755 respin-gui "$DEB_STAGE/usr/bin/respin-gui"
  install -Dm644 respin.desktop "$DEB_STAGE/usr/share/applications/respin.desktop"
  install -Dm644 respin.png "$DEB_STAGE/usr/share/icons/hicolor/512x512/apps/respin.png"
  install -Dm644 respin.png "$DEB_STAGE/usr/share/pixmaps/respin.png"
  install -Dm644 respin.png "$DEB_STAGE/usr/lib/respin/respin.png"
  sed "s/@VERSION@/$VERSION/" packaging/deb/control > "$DEB_STAGE/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$DEB_STAGE" "$DIST_DIR/respin_${VERSION}-1_all.deb"
  rm -rf "$DEB_STAGE"
else
  echo "==> Skipping .deb (dpkg-deb not found — install 'dpkg')" >&2
fi

# ---------------------------------------------------------------------------
# .rpm
# ---------------------------------------------------------------------------
if command -v rpmbuild >/dev/null 2>&1; then
  echo "==> Building .rpm"
  RPM_TOPDIR="$DIST_DIR/rpmbuild"
  mkdir -p "$RPM_TOPDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cp "${SRC_FILES[@]}" "$RPM_TOPDIR/SOURCES/"
  rpmbuild --define "_topdir $RPM_TOPDIR" \
           --define "_respin_version $VERSION" \
           -bb packaging/rpm/respin.spec
  find "$RPM_TOPDIR/RPMS" -name '*.rpm' -exec mv {} "$DIST_DIR/" \;
  rm -rf "$RPM_TOPDIR"
else
  echo "==> Skipping .rpm (rpmbuild not found — install 'rpm-tools')" >&2
fi

echo ""
echo "Done. Artifacts in dist/:"
ls -la "$DIST_DIR"
