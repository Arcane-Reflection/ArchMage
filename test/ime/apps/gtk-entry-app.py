#!/usr/bin/env python3
# gtk-entry-app.py — IME commit ground-truth capture app (03-01, IME-01/02/03).
#
# Minimal python-gobject window with a single Gtk.Entry. Everything the input
# method delivers to (or buffers in) the entry is written line-by-line to the
# log file named by $ARCHMAGE_IME_APP_LOG. This log is the GROUND TRUTH for
# the end-to-end assertion: the harness greps it for the committed string
# (「你好」) and asserts the raw pinyin (nihao) never landed in the buffer.
#
# Usage:
#   ARCHMAGE_IME_APP_LOG=/path/app.log python3 gtk-entry-app.py [--gtk {3,4}]
#
# Log protocol (one JSON object per line, flushed immediately):
#   {"event": "app-start", ...}        process started, Gtk version in use
#   {"event": "app-mapped", ...}       window mapped on the Wayland surface
#   {"event": "entry-focus-in", ...}   the entry holds keyboard focus
#   {"event": "preedit", "text": ...}  IM preedit visible in the entry
#   {"event": "text-changed", ...}     entry buffer content after the change
#   {"event": "activate", ...}         Enter pressed in the entry
#
# GTK_IM_MODULE must be UNSET for the Wayland rows: GTK3/4 then talk to
# fcitx5 through the native text-input-v3 Wayland protocol (research Q1
# matrix). Set WAYLAND_DEBUG=1 in the environment (from the run script, not
# here) to record the client-side Wayland protocol trace as a probe artifact.

import json
import os
import sys

import gi

gtk_version = "4.0"
args = sys.argv[1:]
if "--gtk" in args:
    i = args.index("--gtk")
    want = args[i + 1]
    gtk_version = {"3": "3.0", "4": "4.0"}[want]

gi.require_version("Gtk", gtk_version)
if gtk_version == "4.0":
    from gi.repository import Gtk, GLib  # noqa: E402
else:
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gtk, GLib, Gdk  # noqa: E402

LOG_PATH = os.environ.get("ARCHMAGE_IME_APP_LOG")
if not LOG_PATH:
    print("ARCHMAGE_IME_APP_LOG is required", file=sys.stderr)
    sys.exit(2)


def log_event(**fields):
    rec = {"event": fields.pop("event"), "gtk": gtk_version, **fields}
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


class EntryApp:
    def __init__(self):
        self.app = Gtk.Application(application_id="org.archmage.ime.gtk-entry-app")
        self.app.connect("activate", self.on_activate)

    def on_activate(self, _app):
        self.win = Gtk.ApplicationWindow(application=self.app)
        self.win.set_title("archmage-ime-gtk")
        self.entry = Gtk.Entry()
        self.entry.set_placeholder_text("type here")
        self.entry.set_margin_top(120)
        self.entry.set_margin_bottom(120)
        self.entry.set_margin_start(60)
        self.entry.set_margin_end(60)
        self.entry.set_hexpand(True)
        if gtk_version == "4.0":
            self.win.set_child(self.entry)
            focus = Gtk.EventControllerFocus()
            focus.connect("enter", self.on_focus_in)
            self.entry.add_controller(focus)
        else:
            self.win.add(self.entry)
            self.entry.connect("focus-in-event", self.on_focus_in_gtk3)

        self.entry.connect("changed", self.on_changed)
        self.entry.connect("activate", self.on_activate_entry)
        if gtk_version == "3.0":
            # Gtk3 exposes the IM preedit directly.
            self.entry.connect("preedit-changed", self.on_preedit_gtk3)

        self.win.connect("map", self.on_map)
        self.win.present()

    def on_map(self, *_a):
        log_event(event="app-mapped", pid=os.getpid())

    def on_focus_in(self, *_a):
        log_event(event="entry-focus-in")

    def on_focus_in_gtk3(self, *_a):
        GLib.idle_add(lambda: (log_event(event="entry-focus-in"), False)[1])
        return False

    def on_preedit_gtk3(self, _entry, preedit):
        log_event(event="preedit", text=preedit)

    def on_changed(self, entry):
        # Gtk4 has no per-IME preedit signal on Entry; the buffered text
        # after each change IS the ground truth we assert on.
        log_event(event="text-changed", text=entry.get_text())

    def on_activate_entry(self, entry):
        log_event(event="activate", text=entry.get_text())


if __name__ == "__main__":
    log_event(event="app-start", pid=os.getpid())
    raise SystemExit(EntryApp().app.run(None))
