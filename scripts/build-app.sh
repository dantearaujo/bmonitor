#!/bin/zsh
# Monta "bmonitor.app" com a libsrt e o OpenSSL dentro do pacote (uma atualização do
# Homebrew não quebra o app), ícone gerado por scripts/make-icon.swift e assinatura ad hoc.
# Uso: scripts/build-app.sh [--notarize] [--install] [--dmg]
#   --notarize notariza o app (e o .dmg, com --dmg) e anexa o selo da Apple; exige o .env
#   --install copia para /Applications; --dmg gera .build/dist/bmonitor-<versão>.dmg
# Assinatura: com SIGNING_IDENTITY no .env (Developer ID), assina com hardened runtime e
# carimbo de tempo; sem .env, assina ad hoc (serve para compilar e testar localmente).
# O .env (fora do git) traz SIGNING_IDENTITY e NOTARY_PROFILE, o perfil do notarytool no Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="bmonitor"
APP=".build/dist/$NAME.app"
BUNDLE_ID="com.dantearaujo.bmonitor"
VERSION="0.9.2"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)

swift build -c release
mkdir -p .build/icon
swift scripts/make-icon.swift .build/icon >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/bmonitor "$APP/Contents/MacOS/"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Traduções: português é a base (chaves no código); en.lproj traduz para inglês.
cp -R Localization/*.lproj "$APP/Contents/Resources/"

# Bibliotecas do Homebrew para dentro do pacote, com os caminhos trocados para @rpath.
BIN="$APP/Contents/MacOS/bmonitor"
SRT=$(otool -L "$BIN" | awk '/libsrt/{print $1}')
SSL=$(otool -L "$SRT" | awk '/libssl/{print $1}')
CRYPTO=$(otool -L "$SRT" | awk '/libcrypto/{print $1}')
for lib in "$SRT" "$SSL" "$CRYPTO"; do
    cp "$lib" "$APP/Contents/Frameworks/"
    chmod u+w "$APP/Contents/Frameworks/$(basename "$lib")"
done
FW="$APP/Contents/Frameworks"
relink() {  # relink <arquivo> <biblioteca>: troca toda referência à biblioteca por @rpath
    local file=$1 lib=$(basename "$2")
    for ref in $(otool -L "$file" | awk 'NR>1{print $1}' | grep "$lib" || true); do
        install_name_tool -change "$ref" "@rpath/$lib" "$file" 2>/dev/null
    done
}
for lib in "$SRT" "$SSL" "$CRYPTO"; do
    f="$FW/$(basename "$lib")"
    install_name_tool -id "@rpath/$(basename "$lib")" "$f" 2>/dev/null
    for dep in "$SSL" "$CRYPTO"; do relink "$f" "$dep"; done
done
relink "$BIN" "$SRT"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>bmonitor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>pt-BR</string>
    </array>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>O bmonitor procura o iPhone com o Blackmagic Camera na rede local para mostrar o vídeo e controlar a câmera.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_http._tcp</string>
        <string>_bmd-cam-control._tcp</string>
    </array>
</dict>
</plist>
PLIST

SIGNING_IDENTITY=""
NOTARY_PROFILE=""
[[ -f .env ]] && source .env
NOTARIZE=false
for arg in "$@"; do [[ "$arg" == "--notarize" ]] && NOTARIZE=true; done
if $NOTARIZE && [[ -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
    echo "erro: --notarize exige SIGNING_IDENTITY e NOTARY_PROFILE no .env" >&2
    exit 1
fi

# Assinatura de dentro para fora: bibliotecas, depois o app.
if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGN=(codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY")
else
    SIGN=(codesign --force --sign -)
fi
for f in "$FW"/*.dylib; do "${SIGN[@]}" "$f"; done
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

# notarize <arquivo>: envia à Apple, espera o resultado e falha se não for aceito.
notarize() {
    local result
    result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
    echo "$result" | grep -E "id:|status:" | tail -2
    if ! echo "$result" | grep -q "status: Accepted"; then
        local id=$(echo "$result" | awk '/id:/{print $2; exit}')
        echo "erro: a Apple recusou $1. Veja: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
}

if $NOTARIZE; then
    echo "notarizando o app…"
    ditto -c -k --keepParent "$APP" .build/dist/notarize.zip
    notarize .build/dist/notarize.zip
    rm .build/dist/notarize.zip
    xcrun stapler staple -q "$APP"
fi

# Conferência: nenhuma referência ao Homebrew pode sobrar.
if otool -L "$BIN" "$FW"/*.dylib | grep -q /opt/homebrew; then
    echo "erro: ainda há referência ao Homebrew" >&2
    exit 1
fi
echo "pronto: $APP (versão $VERSION, build $BUILD)"

for arg in "$@"; do
    case "$arg" in
    --install)
        rm -rf "/Applications/$NAME.app"
        cp -R "$APP" /Applications/
        echo "instalado em /Applications/$NAME.app"
        ;;
    --dmg)
        # Janela de arrastar para Aplicativos com fundo próprio (dmgbuild grava o layout no
        # .DS_Store do volume, sem automatizar o Finder).
        DMG=".build/dist/$NAME-$VERSION.dmg"
        rm -f "$DMG"
        [[ -x .build/venv/bin/dmgbuild ]] || { python3 -m venv .build/venv && .build/venv/bin/pip install -q dmgbuild; }
        # Notarizado, o rodapé do fundo não precisa ensinar o "Abrir Mesmo Assim".
        if $NOTARIZE; then swift scripts/make-dmg-background.swift .build/dmg-bg --notarized >/dev/null
        else swift scripts/make-dmg-background.swift .build/dmg-bg >/dev/null; fi
        .build/venv/bin/dmgbuild -s scripts/dmg-settings.py -D app="$APP" \
            -D background=.build/dmg-bg/background.png -D icon=.build/icon/AppIcon.icns "$NAME" "$DMG" >/dev/null
        [[ -n "$SIGNING_IDENTITY" ]] && codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
        if $NOTARIZE; then
            echo "notarizando o dmg…"
            notarize "$DMG"
            xcrun stapler staple -q "$DMG"
        fi
        # Cópia sem versão no nome: o link fixo do README (releases/latest/download/bmonitor.dmg)
        # baixa sempre a release marcada como "latest".
        cp "$DMG" ".build/dist/$NAME.dmg"
        echo "dmg: $DMG e .build/dist/$NAME.dmg ($(du -h "$DMG" | cut -f1))"
        ;;
    esac
done
