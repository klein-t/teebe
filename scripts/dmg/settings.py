# dmgbuild settings for the teebe.io download DMG.
# Plain grey window, two big icons (teebe left, Applications right), centered.
# dmgbuild writes the window settings directly (no Finder), so it builds on CI.
# NOTE: on macOS 26 (Tahoe) Finder shows its toolbar/status bar on dmg windows
# regardless of the hide flags below — an OS limitation, not ours. Older macOS
# honors them and shows a clean, chrome-less window.
import os.path

app = defines.get('app', 'teebe.app')
bg  = defines.get('bg', 'dmg-background.png')

format    = 'UDZO'
files     = [app]
symlinks  = {'Applications': '/Applications'}
icon_size = 160
text_size = 13

show_status_bar = False
show_tab_view   = False
show_toolbar    = False
show_pathbar    = False
show_sidebar    = False
default_view    = 'icon-view'
include_icon_view_settings = True

background  = bg
window_rect = ((200, 120), (600, 440))
icon_locations = {
    os.path.basename(app): (150, 160),
    'Applications':        (450, 160),
}
