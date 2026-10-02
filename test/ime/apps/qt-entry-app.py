#!/usr/bin/env python3
# qt-entry-app.py — Qt-side IME commit ground-truth capture app (03-01, IME-03).
#
# Same log protocol as test/ime/apps/gtk-entry-app.py: everything the input
# method delivers into the QLineEdit buffer is written line-by-line (JSON)
# to $ARCHMAGE_IME_APP_LOG. python-gobject cannot serve Qt, so this uses
# PyQt: --qt 5 selects python-pyqt5, --qt 6 selects python-pyqt6.
#
# Qt5 row runs with QT_IM_MODULE=fcitx (fcitx5-qt plugin; Qt < 6.7 has no
# text-input-v3 client). Qt6 row runs with QT_IM_MODULES=wayland;fcitx;ibus.

import json
import os
import sys

binding = "5"
if "--qt" in sys.argv:
    i = sys.argv.index("--qt")
    binding = sys.argv[i + 1]

if binding == "6":
    from PyQt6.QtWidgets import QApplication, QMainWindow, QLineEdit
else:
    from PyQt5.QtWidgets import QApplication, QMainWindow, QLineEdit

LOG_PATH = os.environ.get("ARCHMAGE_IME_APP_LOG")
if not LOG_PATH:
    print("ARCHMAGE_IME_APP_LOG is required", file=sys.stderr)
    sys.exit(2)


def log_event(**fields):
    rec = {"event": fields.pop("event"), "qt": binding, **fields}
    with open(LOG_PATH, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


class Win(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("archmage-ime-qt")
        self.entry = QLineEdit()
        self.entry.setPlaceholderText("type here")
        self.setCentralWidget(self.entry)
        self.entry.textChanged.connect(self.on_changed)
        self.entry.returnPressed.connect(self.on_return)
        self.entry.installEventFilter(self)

    def showEvent(self, ev):
        super().showEvent(ev)
        log_event(event="app-mapped", pid=os.getpid())

    def eventFilter(self, obj, ev):
        # Works on both bindings: QFocusEvent with gotFocus().
        if type(ev).__name__ == "QFocusEvent" and ev.gotFocus():
            log_event(event="entry-focus-in")
        return super().eventFilter(obj, ev)

    def on_changed(self, text):
        # The buffer content after each change IS the ground truth we
        # assert on (preedit never lands in the QLineEdit buffer).
        log_event(event="text-changed", text=text)

    def on_return(self):
        log_event(event="activate", text=self.entry.text())


if __name__ == "__main__":
    log_event(event="app-start", pid=os.getpid())
    app = QApplication(sys.argv)
    win = Win()
    win.show()
    sys.exit(app.exec())
