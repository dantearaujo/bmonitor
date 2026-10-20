# Configuração do dmgbuild para o .dmg do bmonitor. Chamado por scripts/build-app.sh com
# -D app=<caminho do .app> -D background=<png 1x; o @2x ao lado vira a versão Retina>
# -D icon=<AppIcon.icns>. As posições batem com scripts/make-dmg-background.swift.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]

# Altura além dos 400 do fundo: barra de título e a barra inferior, que o Finder do macOS 26
# mostra mesmo com show_status_bar = False.
window_rect = ((200, 140), (660, 460))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
icon_size = 128
text_size = 13
icon_locations = {app_name: (180, 196), "Applications": (480, 196)}

format = "UDZO"
