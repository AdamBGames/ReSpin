Name:           respin
Version:        %{_respin_version}
Release:        1%{?dist}
Summary:        Backup, rebuild, and app-fixer for the webtop container, with a GUI front-end
License:        MIT
URL:            https://github.com/AdamBisCoding/ReSpin
BuildArch:      noarch

Source0:        respin.sh
Source1:        respin_gui.py
Source2:        respin-gui
Source3:        respin.desktop
Source4:        respin.png

Requires:       bash, python3, python3-tkinter
Recommends:     fzf, flatpak, git, dialog

%description
A backup/rebuild tool that works on Arch, Debian/Ubuntu, Fedora/RHEL,
openSUSE, Alpine, and Void. Snapshots whatever is actually explicitly
installed on the box so a reinstall rebuilds the machine as it really
was, and does a one-shot fix for Chromium/Electron/QtWebEngine apps
(Falkon, Discord, VS Code, etc.) that silently refuse to open.

%prep
# Sources are plain files, not a tarball - nothing to unpack.

%build
# Nothing to build - respin is shell + Python, installed as-is.

%install
rm -rf %{buildroot}
install -Dm755 %{SOURCE0} %{buildroot}%{_bindir}/respin
install -Dm755 %{SOURCE1} %{buildroot}%{_prefix}/lib/respin/respin_gui.py
install -Dm755 %{SOURCE2} %{buildroot}%{_bindir}/respin-gui
install -Dm644 %{SOURCE3} %{buildroot}%{_datadir}/applications/respin.desktop
install -Dm644 %{SOURCE4} %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/respin.png
install -Dm644 %{SOURCE4} %{buildroot}%{_datadir}/pixmaps/respin.png
install -Dm644 %{SOURCE4} %{buildroot}%{_prefix}/lib/respin/respin.png

%files
%{_bindir}/respin
%{_bindir}/respin-gui
%{_prefix}/lib/respin/respin_gui.py
%{_prefix}/lib/respin/respin.png
%{_datadir}/applications/respin.desktop
%{_datadir}/icons/hicolor/512x512/apps/respin.png
%{_datadir}/pixmaps/respin.png

%changelog
* Tue Aug 18 2026 AdamBisCoding <https://github.com/AdamBisCoding> - %{_respin_version}-1
- See README.md and git history for changes.
