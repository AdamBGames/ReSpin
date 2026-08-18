pkgname=respin
pkgver=1.0.2
pkgrel=1
pkgdesc="Backup, rebuild, and app-fixer for the webtop container, with a GUI front-end"
arch=(any)
url="https://github.com/AdamBisCoding/ReSpin"
license=(MIT)
depends=(bash pacman sudo python tk)
optdepends=('fzf: interactive package search from the CLI (respin search)'
            'flatpak: restore/reinstall Flatpak apps'
            'git: bootstrap yay for AUR/foreign packages'
            'dialog: full-screen TUI menu (falls back to a plain-text menu without it)'
            'libnewt: alternative full-screen TUI menu via whiptail, if dialog is not installed'
            'fish: fish support for npm-path-setup (bash/zsh are covered by base depends)'
            'nodejs-npm: what npm-path-setup configures your shell PATH for')
source=(respin.sh respin_gui.py respin-gui respin.desktop respin.png)
sha256sums=(SKIP SKIP SKIP SKIP SKIP)

package() {
  install -Dm755 "$srcdir/respin.sh" "$pkgdir/usr/bin/respin"
  install -Dm755 "$srcdir/respin_gui.py" "$pkgdir/usr/lib/respin/respin_gui.py"
  install -Dm755 "$srcdir/respin-gui" "$pkgdir/usr/bin/respin-gui"
  install -Dm644 "$srcdir/respin.desktop" "$pkgdir/usr/share/applications/respin.desktop"
  install -Dm644 "$srcdir/respin.png" "$pkgdir/usr/share/icons/hicolor/512x512/apps/respin.png"
  install -Dm644 "$srcdir/respin.png" "$pkgdir/usr/share/pixmaps/respin.png"
  install -Dm644 "$srcdir/respin.png" "$pkgdir/usr/lib/respin/respin.png"
}
