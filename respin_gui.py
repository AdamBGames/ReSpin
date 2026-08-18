#!/usr/bin/env python3
"""A native GUI front-end for the ReSpin backup/rebuild/app-fixer script."""

from __future__ import annotations

import queue
import subprocess
import threading
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

RESPIN_BIN = "respin"
RESPIN_HOME = Path.home() / ".respin"
BACKUPS_DIR = RESPIN_HOME / "backups"
EXTRA_PACKAGES_FILE = RESPIN_HOME / "extra-packages.txt"

# Checked in order: sibling file (running straight from the repo), then the
# two locations the PKGBUILD installs the icon to.
ICON_PATHS = [
    Path(__file__).resolve().with_name("respin.png"),
    Path("/usr/lib/respin/respin.png"),
    Path("/usr/share/icons/hicolor/512x512/apps/respin.png"),
]

# ---------------------------------------------------------------------------
# Design tokens - a dark, flat palette in the vein of modern dev-tool UIs
# (GitHub Desktop, Linear, Vercel's dashboard): near-black surfaces at three
# elevations, a single blue accent reserved for primary actions, red reserved
# for destructive ones, and everything else neutral gray. One source of
# truth here instead of colors scattered through every widget call.
# ---------------------------------------------------------------------------
BG = "#12141a"
SURFACE = "#1b1e26"
SURFACE_ALT = "#242832"
SURFACE_RAISED = "#2c313d"
BORDER = "#2f3440"
TEXT = "#eef1f7"
TEXT_MUTED = "#9098ab"
TEXT_FAINT = "#5c6376"
ACCENT = "#5b8cff"
ACCENT_HOVER = "#4a76e6"
ACCENT_PRESS = "#3c62c9"
ACCENT_DISABLED = "#33415e"
DANGER = "#f16472"
DANGER_HOVER = "#dd4f5e"
DANGER_PRESS = "#c23e4c"
DANGER_DISABLED = "#5b3a41"
SUCCESS = "#3ecf8e"
WARNING = "#f2b84b"
LOG_BG = "#0b0d12"
LOG_TEXT = "#d9deea"

FONT = "Sans"
MONO = "Monospace"


def spaced(text: str) -> str:
    """'ACTIONS' -> 'A C T I O N S' - a cheap letter-tracking effect for
    small section headers, since Tk has no real letter-spacing property."""
    return " ".join(text)


def load_icon(widget: tk.Misc) -> tk.PhotoImage | None:
    for path in ICON_PATHS:
        if path.is_file():
            try:
                return tk.PhotoImage(master=widget, file=str(path))
            except tk.TclError:
                continue
    return None


def read_extras() -> list[str]:
    if not EXTRA_PACKAGES_FILE.exists():
        return []
    return sorted(line.strip() for line in EXTRA_PACKAGES_FILE.read_text().splitlines() if line.strip())


def write_extras(packages: set[str]) -> None:
    RESPIN_HOME.mkdir(parents=True, exist_ok=True)
    text = "\n".join(sorted(packages))
    EXTRA_PACKAGES_FILE.write_text(text + ("\n" if text else ""))


def detect_pkg_manager() -> str:
    try:
        result = subprocess.run([RESPIN_BIN, "pkg-manager"], capture_output=True, text=True, timeout=10, check=False)
        name = result.stdout.strip()
        return name or "unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def style_toplevel(win: tk.Toplevel) -> None:
    """Shared dark chrome for dialog windows - everything below the title
    bar is real widgets, so this just sets the base window background."""
    win.configure(background=SURFACE)


def style_listbox(box: tk.Listbox) -> None:
    box.configure(
        background=SURFACE_ALT, foreground=TEXT,
        selectbackground=ACCENT, selectforeground="#ffffff",
        highlightthickness=1, highlightbackground=BORDER, highlightcolor=ACCENT,
        relief="flat", borderwidth=0, font=(FONT, 10),
    )


def style_checkbutton(box: tk.Checkbutton) -> None:
    box.configure(
        background=SURFACE, foreground=TEXT, activebackground=SURFACE,
        activeforeground=TEXT, selectcolor=SURFACE_ALT, highlightthickness=0,
        font=(FONT, 10),
    )


def bordered_card(parent: tk.Misc, padding: int = 16, background: str = SURFACE) -> tuple[tk.Frame, tk.Frame]:
    """A plain-Tk frame with a thin 1px outline, padded inside. ttk's
    'clam' theme won't reliably draw a border color on TFrame, but
    highlightthickness/highlightbackground are base-Tk and work regardless
    of theme - used to give the action/output cards a visible edge instead
    of relying only on a background-shade difference. Returns
    (outer_frame_to_grid, inner_frame_to_populate)."""
    outer = tk.Frame(parent, background=background, highlightthickness=1,
                      highlightbackground=BORDER, highlightcolor=BORDER, bd=0)
    inner = tk.Frame(outer, background=background)
    inner.pack(fill="both", expand=True, padx=padding, pady=padding)
    return outer, inner


def _rounded_rect_points(x1: float, y1: float, x2: float, y2: float, radius: float) -> list[float]:
    radius = max(0, min(radius, (x2 - x1) / 2, (y2 - y1) / 2))
    return [
        x1 + radius, y1, x2 - radius, y1, x2, y1, x2, y1 + radius,
        x2, y2 - radius, x2, y2, x2 - radius, y2, x1 + radius, y2,
        x1, y2, x1, y2 - radius, x1, y1 + radius, x1, y1,
    ]


# ttk has no real rounded-corner support, so flat, square-edged buttons are
# the single biggest thing that makes a Tkinter app read as dated next to
# Linear/GitHub Desktop/Vercel-style UIs. RoundedButton draws its own
# rounded rect on a Canvas (smooth=True polygon) instead - no new
# dependency, since this still has to install cleanly via plain
# `python3-tk` on six different distros.
_BUTTON_STYLES = {
    "primary":   dict(bg=ACCENT, hover=ACCENT_HOVER, press=ACCENT_PRESS,
                       disabled=ACCENT_DISABLED, fg="#ffffff", fg_disabled=TEXT_FAINT, border=None),
    "danger":    dict(bg=DANGER, hover=DANGER_HOVER, press=DANGER_PRESS,
                       disabled=DANGER_DISABLED, fg="#ffffff", fg_disabled=TEXT_FAINT, border=None),
    "secondary": dict(bg=SURFACE_ALT, hover=SURFACE_RAISED, press=SURFACE_RAISED,
                       disabled=SURFACE, fg=TEXT, fg_disabled=TEXT_FAINT, border=BORDER),
}


class RoundedButton(tk.Canvas):
    RADIUS = 10

    def __init__(self, parent: tk.Misc, text: str, command=None, style: str = "secondary",
                 bg: str = SURFACE, height: int = 40, font=(FONT, 10, "bold"), **kwargs) -> None:
        super().__init__(parent, width=160, height=height, background=bg,
                          highlightthickness=0, bd=0, **kwargs)
        self.command = command
        self.colors = _BUTTON_STYLES[style]
        self.font = font
        self.text = text
        self.enabled = True
        self._state = "idle"  # idle | hover | press
        self.bind("<Configure>", self._redraw)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<ButtonPress-1>", self._on_press)
        self.bind("<ButtonRelease-1>", self._on_release)

    def _fill_color(self) -> str:
        if not self.enabled:
            return self.colors["disabled"]
        return {"press": self.colors["press"], "hover": self.colors["hover"]}.get(self._state, self.colors["bg"])

    def _redraw(self, _event=None) -> None:
        w, h = self.winfo_width(), self.winfo_height()
        if w <= 1 or h <= 1:
            return
        self.delete("all")
        fill = self._fill_color()
        outline = self.colors["border"] or fill
        self.create_polygon(_rounded_rect_points(1, 1, w - 1, h - 1, self.RADIUS),
                             smooth=True, fill=fill, outline=outline, width=1)
        fg = self.colors["fg"] if self.enabled else self.colors["fg_disabled"]
        self.create_text(w / 2, h / 2, text=self.text, fill=fg, font=self.font)

    def _on_enter(self, _event=None) -> None:
        if not self.enabled:
            return
        self._state = "hover"
        self.configure(cursor="hand2")
        self._redraw()

    def _on_leave(self, _event=None) -> None:
        self._state = "idle"
        self._redraw()

    def _on_press(self, _event=None) -> None:
        if self.enabled:
            self._state = "press"
            self._redraw()

    def _on_release(self, event) -> None:
        if not self.enabled:
            return
        self._state = "hover"
        self._redraw()
        if 0 <= event.x <= self.winfo_width() and 0 <= event.y <= self.winfo_height() and self.command:
            self.command()

    def configure_state(self, enabled: bool) -> None:
        self.enabled = enabled
        self._state = "idle"
        self.configure(cursor="hand2" if enabled else "arrow")
        self._redraw()


class RoundedBadge(tk.Canvas):
    """A small canvas-drawn pill - used for the package-manager badge and
    the summary chips, so they read as pills instead of Tkinter's
    characteristically square Label boxes. With stretch=True it fills
    whatever width the grid gives it (used for the full-width stat chips);
    otherwise it self-sizes to its text (used for the compact header badge).
    """

    RADIUS = 10

    def __init__(self, parent: tk.Misc, text: str = "", textvariable: tk.StringVar | None = None,
                 bg: str = BG, fill: str = SURFACE_ALT, fg: str = TEXT_MUTED,
                 font=(FONT, 9, "bold"), padx: int = 12, pady: int = 8,
                 stretch: bool = False, **kwargs) -> None:
        super().__init__(parent, background=bg, highlightthickness=0, bd=0, **kwargs)
        self.fill, self.fg, self.font = fill, fg, font
        self.padx, self.pady, self.stretch = padx, pady, stretch
        self._var = textvariable
        self._text = text
        if textvariable is not None:
            textvariable.trace_add("write", lambda *_: self._redraw())
        if stretch:
            self.bind("<Configure>", self._redraw)
        self._redraw()

    def _current_text(self) -> str:
        return self._var.get() if self._var is not None else self._text

    def _redraw(self, _event=None) -> None:
        text = self._current_text()
        self.delete("all")
        probe = self.create_text(0, 0, text=text, font=self.font, anchor="nw")
        bbox = self.bbox(probe)
        self.delete(probe)
        text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
        content_h = text_h + self.pady * 2
        if self.stretch:
            w = max(self.winfo_width(), text_w + self.padx * 2)
            if w <= 1:
                return
            self.configure(height=content_h)
            self.create_polygon(_rounded_rect_points(0, 0, w, content_h, min(self.RADIUS, content_h / 2)),
                                 smooth=True, fill=self.fill, outline=self.fill)
            self.create_text(self.padx, content_h / 2, text=text, fill=self.fg, font=self.font, anchor="w")
        else:
            w = text_w + self.padx * 2
            self.configure(width=w, height=content_h)
            self.create_polygon(_rounded_rect_points(0, 0, w, content_h, min(self.RADIUS, content_h / 2)),
                                 smooth=True, fill=self.fill, outline=self.fill)
            self.create_text(w / 2, content_h / 2, text=text, fill=self.fg, font=self.font)


class RespinGui(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("ReSpin")
        self.minsize(920, 700)
        self.configure(background=BG)
        self._icon = load_icon(self)
        self._header_icon = None
        if self._icon is not None:
            self.iconphoto(True, self._icon)
            try:
                self._header_icon = self._icon.subsample(40, 40)
            except tk.TclError:
                self._header_icon = None
        self.status = tk.StringVar(value="Ready")
        self.last_backup_label = tk.StringVar(value="No backups yet")
        self.extras_label = tk.StringVar(value="0 extra package(s) queued")
        self.job_running = False
        self.log_queue: "queue.Queue[object]" = queue.Queue()
        self.action_buttons: list[ttk.Button] = []
        self.pkg_manager = detect_pkg_manager()
        self._configure_style()
        self._build_ui()
        self._refresh_backups()
        self._refresh_extra_packages()
        self._poll_log_queue()

    def _configure_style(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")

        style.configure("App.TFrame", background=BG)
        style.configure("Card.TFrame", background=SURFACE)

        style.configure("Title.TLabel", background=BG, foreground=TEXT, font=(FONT, 22, "bold"))
        style.configure("Subtitle.TLabel", background=BG, foreground=TEXT_MUTED, font=(FONT, 10))
        style.configure("Section.TLabel", background=BG, foreground=TEXT_FAINT, font=(FONT, 9, "bold"))
        style.configure("CardTitle.TLabel", background=SURFACE, foreground=TEXT, font=(FONT, 11, "bold"))
        style.configure("Muted.TLabel", background=SURFACE, foreground=TEXT_MUTED, font=(FONT, 9))
        style.configure("MutedApp.TLabel", background=BG, foreground=TEXT_MUTED, font=(FONT, 9))

        style.configure("StatusDot.TLabel", background=BG, foreground=TEXT_MUTED, font=(FONT, 10))
        style.configure("Status.TLabel", background=BG, foreground=TEXT_MUTED, font=(FONT, 10))

        style.configure("Dark.TEntry", fieldbackground=SURFACE_ALT, foreground=TEXT, insertcolor=TEXT,
                         bordercolor=BORDER, lightcolor=BORDER, darkcolor=BORDER, borderwidth=1, padding=8)
        style.map("Dark.TEntry", bordercolor=[("focus", ACCENT)])

    # -- layout ------------------------------------------------------------

    def _build_ui(self) -> None:
        root = ttk.Frame(self, style="App.TFrame", padding=24)
        root.grid(sticky="nsew")
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(4, weight=1)

        self._build_header(root).grid(row=0, column=0, sticky="ew", pady=(0, 20))
        self._build_section_label(root, "ACTIONS").grid(row=1, column=0, sticky="w", pady=(0, 8))
        self._build_actions(root).grid(row=2, column=0, sticky="ew", pady=(0, 20))
        self._build_stats(root).grid(row=3, column=0, sticky="ew", pady=(0, 20))
        self._build_output(root).grid(row=4, column=0, sticky="nsew")

        footer = ttk.Frame(root, style="App.TFrame")
        footer.grid(row=5, column=0, sticky="ew", pady=(14, 0))
        ttk.Label(footer, text="●", style="StatusDot.TLabel").pack(side="left", padx=(0, 6))
        ttk.Label(footer, textvariable=self.status, style="Status.TLabel").pack(side="left")

    def _build_section_label(self, parent: tk.Misc, text: str) -> ttk.Label:
        return ttk.Label(parent, text=spaced(text), style="Section.TLabel")

    def _build_header(self, parent: tk.Misc) -> ttk.Frame:
        header = ttk.Frame(parent, style="App.TFrame")
        header.columnconfigure(1, weight=1)

        if self._header_icon is not None:
            icon_label = tk.Label(header, image=self._header_icon, background=BG, borderwidth=0)
            icon_label.grid(row=0, column=0, rowspan=2, sticky="nw", padx=(0, 14))

        title_row = ttk.Frame(header, style="App.TFrame")
        title_row.grid(row=0, column=1, sticky="ew")
        ttk.Label(title_row, text="ReSpin", style="Title.TLabel").pack(side="left")

        badge_text = self.pkg_manager.upper() if self.pkg_manager != "unknown" else "NO PACKAGE MANAGER"
        RoundedBadge(title_row, text=badge_text, bg=BG, fill=SURFACE_ALT, fg=ACCENT,
                     font=(FONT, 9, "bold"), padx=10, pady=5).pack(side="left", padx=(12, 0), pady=(6, 0))

        subtitle = "Backup, rebuild, and fix apps that won't open - across Arch, Debian, Fedora, openSUSE, Alpine, and Void."
        if self.pkg_manager == "unknown":
            subtitle = "No supported package manager found (pacman/apt/dnf/zypper/apk/xbps) - most actions will fail."
        ttk.Label(header, text=subtitle, style="Subtitle.TLabel").grid(row=1, column=1, sticky="ew", pady=(4, 0))
        return header

    def _build_actions(self, parent: tk.Misc) -> tk.Frame:
        outer, card = bordered_card(parent, padding=18)
        for c in range(2):
            card.columnconfigure(c, weight=1)

        backup_btn = RoundedButton(card, "Backup now", style="primary", height=44, command=self.run_backup)
        backup_btn.grid(row=0, column=0, sticky="ew", padx=(0, 8), pady=(0, 8))
        fix_btn = RoundedButton(card, "Fix broken apps", style="primary", height=44, command=self.run_fix_apps)
        fix_btn.grid(row=0, column=1, sticky="ew", padx=(8, 0), pady=(0, 8))

        search_btn = RoundedButton(card, "Search packages...", style="secondary", height=38, command=self.open_search_window)
        search_btn.grid(row=1, column=0, sticky="ew", padx=(0, 8), pady=8)
        flatpak_btn = RoundedButton(card, "Install Flatpak + Flathub", style="secondary", height=38, command=self.run_flatpak_setup)
        flatpak_btn.grid(row=1, column=1, sticky="ew", padx=(8, 0), pady=8)

        npm_path_btn = RoundedButton(card, "Configure npm-global PATH...", style="secondary", height=38, command=self.open_npm_path_dialog)
        npm_path_btn.grid(row=2, column=0, sticky="ew", padx=(0, 8), pady=8)
        auto_update_btn = RoundedButton(card, "Set up hourly auto-update", style="secondary", height=38, command=self.run_auto_update_setup)
        auto_update_btn.grid(row=2, column=1, sticky="ew", padx=(8, 0), pady=8)

        add_search_path_btn = RoundedButton(card, "Add app install location...", style="secondary", height=38, command=self.open_add_search_path_dialog)
        add_search_path_btn.grid(row=3, column=0, columnspan=2, sticky="ew", pady=8)

        tk.Frame(card, background=BORDER, height=1).grid(row=4, column=0, columnspan=2, sticky="ew", pady=(6, 10))

        reinstall_btn = RoundedButton(card, "Reinstall from backup...", style="danger", height=44, command=self.open_reinstall_dialog)
        reinstall_btn.grid(row=5, column=0, columnspan=2, sticky="ew")

        self.action_buttons = [backup_btn, fix_btn, search_btn, flatpak_btn, npm_path_btn, auto_update_btn, add_search_path_btn, reinstall_btn]
        return outer

    def _build_stats(self, parent: tk.Misc) -> ttk.Frame:
        row = ttk.Frame(parent, style="App.TFrame")
        row.columnconfigure(0, weight=1)
        row.columnconfigure(1, weight=1)

        backup_chip = RoundedBadge(row, textvariable=self.last_backup_label, bg=BG, fill=SURFACE_ALT,
                                    fg=TEXT, font=(FONT, 9, "bold"), padx=12, pady=8, stretch=True)
        backup_chip.grid(row=0, column=0, sticky="ew", padx=(0, 6))

        extras_chip = RoundedBadge(row, textvariable=self.extras_label, bg=BG, fill=SURFACE_ALT,
                                    fg=TEXT, font=(FONT, 9, "bold"), padx=12, pady=8, stretch=True)
        extras_chip.grid(row=0, column=1, sticky="ew", padx=(6, 0))
        return row

    def _build_output(self, parent: tk.Misc) -> tk.Frame:
        outer, card = bordered_card(parent, padding=16)
        card.columnconfigure(0, weight=1)
        card.rowconfigure(1, weight=1)
        ttk.Label(card, text="Output", style="CardTitle.TLabel").grid(row=0, column=0, sticky="w")
        self.log = ScrolledText(
            card, background=LOG_BG, foreground=LOG_TEXT, insertbackground=LOG_TEXT,
            font=(MONO, 10), relief="flat", borderwidth=0, wrap="word", padx=12, pady=10,
        )
        self.log.grid(row=1, column=0, sticky="nsew", pady=(10, 0))
        return outer

    # -- background job plumbing -------------------------------------------------

    def _set_busy(self, busy: bool) -> None:
        for button in self.action_buttons:
            button.configure_state(not busy)

    def _run_command(self, args: list[str], on_success=None) -> None:
        if self.job_running:
            return
        self.job_running = True
        self._set_busy(True)
        self.log.delete("1.0", tk.END)
        self.status.set(f"Running: respin {' '.join(args)}")
        self._log_line(f"$ respin {' '.join(args)}\n\n")
        threading.Thread(target=self._run_worker, args=(args, on_success), daemon=True).start()

    def _run_worker(self, args: list[str], on_success) -> None:
        try:
            process = subprocess.Popen(
                [RESPIN_BIN, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            for line in process.stdout:
                self.log_queue.put(line)
            returncode = process.wait()
        except OSError as error:
            self.log_queue.put(f"Failed to launch respin: {error}\n")
            returncode = 1
        self.log_queue.put(("__DONE__", returncode, on_success))

    def _poll_log_queue(self) -> None:
        try:
            while True:
                item = self.log_queue.get_nowait()
                if isinstance(item, tuple):
                    _, returncode, on_success = item
                    self.job_running = False
                    self._set_busy(False)
                    self.status.set("Finished" if returncode == 0 else f"Finished (exit {returncode})")
                    if returncode == 0 and on_success:
                        on_success()
                else:
                    self._log_line(item)
        except queue.Empty:
            pass
        self.after(100, self._poll_log_queue)

    def _log_line(self, text: str) -> None:
        self.log.insert(tk.END, text)
        self.log.see(tk.END)

    # -- actions -------------------------------------------------------------

    def run_backup(self) -> None:
        self._run_command(["backup"], on_success=self._refresh_backups_and_extras)

    def run_fix_apps(self) -> None:
        self._run_command(["fix-apps"])

    def run_flatpak_setup(self) -> None:
        self._run_command(["flatpak-setup"], on_success=self._notify_flatpak_logout)

    def run_auto_update_setup(self) -> None:
        self._run_command(["auto-update-setup"])

    def _notify_flatpak_logout(self) -> None:
        messagebox.showinfo(
            "Log out recommended",
            "Flatpak + Flathub are installed. Log out and back in so the "
            "app-menu integration and portals register correctly.",
        )

    def open_add_search_path_dialog(self) -> None:
        directory = filedialog.askdirectory(
            title="Select a directory where apps are installed",
            mustexist=True,
        )
        if not directory:
            return
        self._run_command(["add-search-path", directory])

    def open_search_window(self) -> None:
        SearchWindow(self)

    def open_npm_path_dialog(self) -> None:
        NpmPathDialog(self)

    def run_npm_path_setup(self, shells: list[str]) -> None:
        self._run_command(["npm-path-setup", *shells])

    def open_reinstall_dialog(self) -> None:
        backups = self._list_backups()
        if not backups:
            messagebox.showinfo(
                "No backups yet",
                "Run 'Backup now' first - reinstall replays a snapshot, it doesn't work from nothing.",
            )
            return
        ReinstallDialog(self, backups)

    def start_reinstall(self, backup_path: Path) -> None:
        self._run_command(["reinstall", str(backup_path)], on_success=self._refresh_backups_and_extras)

    # -- state refresh ---------------------------------------------------------

    def _list_backups(self) -> list[Path]:
        if not BACKUPS_DIR.exists():
            return []
        return sorted((p for p in BACKUPS_DIR.iterdir() if p.is_dir()), key=lambda p: p.name, reverse=True)

    def _refresh_backups(self) -> None:
        backups = self._list_backups()
        self.last_backup_label.set(f"Last backup: {backups[0].name}" if backups else "No backups yet")

    def _refresh_extra_packages(self) -> None:
        count = len(read_extras())
        self.extras_label.set(f"{count} extra package(s) queued for next reinstall")

    def _refresh_backups_and_extras(self) -> None:
        self._refresh_backups()
        self._refresh_extra_packages()


class ReinstallDialog(tk.Toplevel):
    def __init__(self, app: RespinGui, backups: list[Path]) -> None:
        super().__init__(app)
        self.app = app
        self.backups = backups
        self.title("Reinstall from backup")
        style_toplevel(self)
        self.resizable(False, False)
        self.transient(app)
        self.grab_set()

        ttk.Label(self, text="Choose a backup to rebuild from:", style="CardTitle.TLabel", background=SURFACE).pack(anchor="w", padx=18, pady=(18, 8))

        listbox_frame = tk.Frame(self, background=SURFACE)
        listbox_frame.pack(fill="both", expand=True, padx=18)
        self.listbox = tk.Listbox(listbox_frame, height=8, exportselection=False)
        style_listbox(self.listbox)
        for backup in backups:
            self.listbox.insert(tk.END, backup.name)
        self.listbox.selection_set(0)
        self.listbox.pack(fill="both", expand=True)

        ttk.Label(
            self,
            text="This runs a full system update and reinstalls the snapshotted package set, "
                 "restores configs, and clears app caches. It can take a while - keep this window open.",
            style="Muted.TLabel",
            background=SURFACE,
            wraplength=380,
        ).pack(anchor="w", padx=18, pady=(12, 4))

        buttons = tk.Frame(self, background=SURFACE)
        buttons.pack(fill="x", padx=18, pady=18)
        buttons.columnconfigure(0, weight=1)
        buttons.columnconfigure(1, weight=1)
        RoundedButton(buttons, "Cancel", style="secondary", command=self.destroy).grid(row=0, column=0, sticky="ew", padx=(0, 6))
        RoundedButton(buttons, "Reinstall", style="danger", command=self._confirm).grid(row=0, column=1, sticky="ew", padx=(6, 0))

    def _confirm(self) -> None:
        selection = self.listbox.curselection()
        if not selection:
            return
        chosen = self.backups[selection[0]]
        if not messagebox.askyesno("Confirm reinstall", f"Rebuild this machine from backup '{chosen.name}'?"):
            return
        self.destroy()
        self.app.start_reinstall(chosen)


class NpmPathDialog(tk.Toplevel):
    """Lets the user pick which shell(s) get ~/.npm-global/bin added to PATH."""

    def __init__(self, app: RespinGui) -> None:
        super().__init__(app)
        self.app = app
        self.title("Configure npm-global PATH")
        style_toplevel(self)
        self.resizable(False, False)
        self.transient(app)
        self.grab_set()
        self.vars: dict[str, tk.BooleanVar] = {}

        ttk.Label(self, text="Add ~/.npm-global/bin to PATH for:", style="CardTitle.TLabel", background=SURFACE).pack(anchor="w", padx=18, pady=(18, 8))

        self.status_label = ttk.Label(self, text="Checking installed shells...", style="Muted.TLabel", background=SURFACE)
        self.status_label.pack(anchor="w", padx=18)

        self.checks_frame = tk.Frame(self, background=SURFACE)
        self.checks_frame.pack(fill="both", padx=18, pady=(6, 4))

        ttk.Label(
            self,
            text="Detected-but-unconfigured shells are pre-checked. This adds the PATH export "
                 "line to each shell's rc file - open a new terminal (or run 'exec $SHELL') "
                 "afterwards to pick up the change.",
            style="Muted.TLabel",
            background=SURFACE,
            wraplength=380,
        ).pack(anchor="w", padx=18, pady=(4, 4))

        buttons = tk.Frame(self, background=SURFACE)
        buttons.pack(fill="x", padx=18, pady=18)
        buttons.columnconfigure(0, weight=1)
        buttons.columnconfigure(1, weight=1)
        RoundedButton(buttons, "Cancel", style="secondary", command=self.destroy).grid(row=0, column=0, sticky="ew", padx=(0, 6))
        self.apply_btn = RoundedButton(buttons, "Apply", style="primary", command=self._apply)
        self.apply_btn.grid(row=0, column=1, sticky="ew", padx=(6, 0))
        self.apply_btn.configure_state(False)

        threading.Thread(target=self._load_shells, daemon=True).start()

    def _load_shells(self) -> None:
        try:
            result = subprocess.run([RESPIN_BIN, "list-shells"], capture_output=True, text=True, timeout=10, check=True)
            rows = [line.split("\t") for line in result.stdout.splitlines() if line.strip()]
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            self.after(0, lambda: self.status_label.configure(text=f"Failed to detect shells: {error}"))
            return
        self.after(0, lambda: self._build_checks(rows))

    def _build_checks(self, rows: list[list[str]]) -> None:
        if not rows:
            self.status_label.configure(text="No supported shells found.")
            return
        self.status_label.configure(text="Detected-but-unconfigured shells are pre-checked:")
        for shell, installed, configured in rows:
            label = shell
            if configured == "yes":
                label += "  (already configured)"
            elif installed == "no":
                label += "  (not detected)"
            var = tk.BooleanVar(value=(installed == "yes" and configured == "no"))
            self.vars[shell] = var
            check = tk.Checkbutton(self.checks_frame, text=label, variable=var, anchor="w")
            style_checkbutton(check)
            check.pack(fill="x")
        self.apply_btn.configure_state(True)

    def _apply(self) -> None:
        chosen = [shell for shell, var in self.vars.items() if var.get()]
        if not chosen:
            messagebox.showinfo("Nothing selected", "Pick at least one shell.")
            return
        self.destroy()
        self.app.run_npm_path_setup(chosen)


class SearchWindow(tk.Toplevel):
    """Two-pane package picker (pacman/apt/dnf/zypper/apk/xbps) - replaces the old fzf terminal search."""

    def __init__(self, app: RespinGui) -> None:
        super().__init__(app)
        self.app = app
        self.title(f"Search packages ({app.pkg_manager})")
        self.geometry("780x560")
        style_toplevel(self)
        self.all_packages: list[str] = []
        self.query = tk.StringVar()
        self.query.trace_add("write", lambda *_: self._filter())
        self._build_ui()
        threading.Thread(target=self._load_packages, daemon=True).start()

    def _build_ui(self) -> None:
        root = ttk.Frame(self, style="Card.TFrame", padding=18)
        root.pack(fill="both", expand=True)
        root.columnconfigure(0, weight=1)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(2, weight=1)

        ttk.Label(root, text="Available packages", style="CardTitle.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(root, text="Queued for next reinstall", style="CardTitle.TLabel").grid(row=0, column=1, sticky="w", padx=(12, 0))

        entry = ttk.Entry(root, textvariable=self.query, style="Dark.TEntry")
        entry.grid(row=1, column=0, sticky="ew", pady=(8, 6))
        entry.focus_set()
        ttk.Label(root, text="(type to filter, select multiple, Add →)", style="Muted.TLabel").grid(row=1, column=1, sticky="w", padx=(12, 0), pady=(8, 6))

        self.available_list = tk.Listbox(root, selectmode=tk.EXTENDED, exportselection=False)
        style_listbox(self.available_list)
        self.available_list.grid(row=2, column=0, sticky="nsew", pady=(0, 10))

        self.queued_list = tk.Listbox(root, selectmode=tk.EXTENDED, exportselection=False)
        style_listbox(self.queued_list)
        self.queued_list.grid(row=2, column=1, sticky="nsew", padx=(12, 0), pady=(0, 10))

        buttons = ttk.Frame(root, style="Card.TFrame")
        buttons.grid(row=3, column=0, columnspan=2, sticky="ew")
        buttons.columnconfigure(0, weight=1)
        buttons.columnconfigure(1, weight=1)
        RoundedButton(buttons, "Add selected →", style="primary", command=self._add_selected).grid(row=0, column=0, sticky="ew", padx=(0, 6))
        RoundedButton(buttons, "← Remove selected", style="secondary", command=self._remove_selected).grid(row=0, column=1, sticky="ew", padx=(6, 0))

        RoundedButton(root, "Install queued packages now", style="danger", command=self._install_queued).grid(row=4, column=0, columnspan=2, sticky="ew", pady=(10, 0))

        self.status_label = ttk.Label(root, text="Loading package list...", style="Muted.TLabel")
        self.status_label.grid(row=5, column=0, columnspan=2, sticky="w", pady=(10, 0))

        self._refresh_queued()

    def _load_packages(self) -> None:
        try:
            result = subprocess.run([RESPIN_BIN, "list-packages"], capture_output=True, text=True, check=True)
            packages = sorted(set(result.stdout.split()))
        except (OSError, subprocess.CalledProcessError) as error:
            self.after(0, lambda: self.status_label.configure(text=f"Failed to list packages: {error}"))
            return
        self.all_packages = packages
        self.after(0, self._filter)

    def _filter(self) -> None:
        query = self.query.get().strip().lower()
        self.available_list.delete(0, tk.END)
        matches = [p for p in self.all_packages if query in p] if query else self.all_packages
        shown = matches[:500]
        for pkg in shown:
            self.available_list.insert(tk.END, pkg)
        total = len(self.all_packages)
        if total:
            suffix = f" (showing first {len(shown)})" if len(matches) > len(shown) else ""
            self.status_label.configure(text=f"{len(matches)} of {total} packages match{suffix}")

    def _refresh_queued(self) -> None:
        self.queued_list.delete(0, tk.END)
        for pkg in read_extras():
            self.queued_list.insert(tk.END, pkg)

    def _add_selected(self) -> None:
        selected = [self.available_list.get(i) for i in self.available_list.curselection()]
        if not selected:
            return
        current = set(read_extras())
        current.update(selected)
        write_extras(current)
        self._refresh_queued()
        self.app._refresh_extra_packages()

    def _remove_selected(self) -> None:
        selected = [self.queued_list.get(i) for i in self.queued_list.curselection()]
        if not selected:
            return
        current = set(read_extras()) - set(selected)
        write_extras(current)
        self._refresh_queued()
        self.app._refresh_extra_packages()

    def _install_queued(self) -> None:
        if self.app.job_running:
            messagebox.showinfo("Busy", "Another ReSpin job is already running - wait for it to finish.")
            return
        queued = read_extras()
        if not queued:
            messagebox.showinfo("Nothing queued", "Add some packages first, then install them.")
            return
        if not messagebox.askyesno("Install now", f"Install {len(queued)} queued package(s) on this machine right now?"):
            return
        self.app._run_command(["install-extras"], on_success=self._after_install)

    def _after_install(self) -> None:
        self.app._refresh_extra_packages()
        if self.winfo_exists():
            self._refresh_queued()


if __name__ == "__main__":
    RespinGui().mainloop()
