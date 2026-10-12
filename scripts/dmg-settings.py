# dmgbuild settings, used by scripts/make-dmg.sh. Positions match scripts/make-dmg-background.swift.
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild -D)
format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]  # noqa: F821
background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 215),
    "Applications": (470, 215),
}
