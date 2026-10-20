#!/bin/zsh
# Monta "bmonitor.app" com a libsrt e o OpenSSL dentro do pacote (uma atualização do
# Homebrew não quebra o app), ícone gerado por scripts/make-icon.swift e assinatura ad hoc.
# Uso: scripts/build-app.sh [--notarize] [--install] [--dmg] [--appcast]
#   --notarize notariza o app (e o .dmg, com --dmg) e anexa o selo da Apple; exige o .env
#   --install copia para /Applications; --dmg gera .build/dist/bmonitor-<versão>.dmg
#   --appcast (com --dmg) gera .build/dist/appcast.xml, assinado com a chave do Sparkle do Keychain
# VERSION e BUILD podem vir do ambiente (teste de atualização com uma versão "antiga").
# Assinatura: com SIGNING_IDENTITY no .env (Developer ID), assina com hardened runtime e
# carimbo de tempo; sem .env, assina ad hoc (serve para compilar e testar localmente).
# O .env (fora do git) traz SIGNING_IDENTITY e NOTARY_PROFILE, o perfil do notarytool no Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="bmonitor"
APP=".build/dist/$NAME.app"
BUNDLE_ID="com.dantearaujo.bmonitor"
VERSION="${VERSION:-0.9.4}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
TAG="v$VERSION-beta"
# Sparkle: o app lê o feed da release mais recente e só aceita atualização assinada com a chave
# privada do Keychain (conta "bmonitor"; cópia no 1Password). A pública é pública: fica aqui.
FEED_URL="https://github.com/dantearaujo/bmonitor/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="Q2Xta7e1dk4Y++tjbOMq04jUAze5kRIJNdobA2M7LMM="
SPARKLE=.build/artifacts/sparkle/Sparkle

# libsrt e OpenSSL compilados aqui (universal, macOS 14+), não os do Homebrew: os do Homebrew
# exigem a versão do macOS da máquina que compilou.
scripts/build-deps.sh
DEPS_LIB="$PWD/.build/deps/universal/lib"
export PKG_CONFIG_PATH="$DEPS_LIB/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS_LIB/pkgconfig"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
mkdir -p .build/icon
swift scripts/make-icon.swift .build/icon >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_PATH/bmonitor" "$APP/Contents/MacOS/"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Traduções: português é a base (chaves no código); en.lproj traduz para inglês.
cp -R Localization/*.lproj "$APP/Contents/Resources/"

# Bibliotecas para dentro do pacote; build-deps.sh já as deixou com nomes @rpath.
BIN="$APP/Contents/MacOS/bmonitor"
FW="$APP/Contents/Frameworks"
for lib in libsrt.1.5.dylib libssl.4.dylib libcrypto.4.dylib; do
    cp "$DEPS_LIB/$lib" "$FW/"
    chmod u+w "$FW/$lib"
done
otool -l "$BIN" | grep -q "@executable_path/../Frameworks" \
    || install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FW/Sparkle.framework"

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
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>O bmonitor procura o iPhone com o Blackmagic Camera na rede local para mostrar o vídeo e controlar a câmera.</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Sparkle: cada executável interno, depois o framework (ordem da documentação do Sparkle).
SP="$FW/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SP/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SP/Autoupdate"
"${SIGN[@]}" "$SP/Updater.app"
"${SIGN[@]}" "$FW/Sparkle.framework"
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

# Conferência: nenhuma referência ao Homebrew, e nenhum binário pedindo mais que o macOS 14.
if otool -L "$BIN" "$FW"/*.dylib | grep -q /opt/homebrew; then
    echo "erro: ainda há referência ao Homebrew" >&2
    exit 1
fi
for f in "$BIN" "$FW"/*.dylib "$FW/Sparkle.framework/Versions/B/Sparkle"; do
    for arch in $(lipo -archs "$f"); do
        minos=$(otool -arch "$arch" -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')
        if [[ -n "$minos" && "${minos%%.*}" -gt 14 ]]; then
            echo "erro: $(basename "$f") ($arch) exige macOS $minos" >&2
            exit 1
        fi
    done
done
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
    --appcast)
        # Feed com a versão deste build. Rode depois de --dmg: assina o .dmg final (já com selo).
        rm -rf .build/appcast && mkdir -p .build/appcast
        cp ".build/dist/$NAME-$VERSION.dmg" .build/appcast/
        "$SPARKLE/bin/generate_appcast" --account bmonitor \
            --download-url-prefix "https://github.com/dantearaujo/bmonitor/releases/download/$TAG/" .build/appcast
        cp .build/appcast/appcast.xml .build/dist/appcast.xml
        echo "appcast: .build/dist/appcast.xml (release $TAG)"
        ;;
    esac
done
