#!/bin/bash
# Protótipo da webcam virtual: monta "bmonitor Dev.app" (com.dantearaujo.bmonitor.dev) com a
# extensão de câmera dentro e instala em /Applications, ao lado do bmonitor de verdade.
#
# 1. O Xcode compila a extensão e um app mínimo (Webcam/project.yml) com assinatura automática
#    de desenvolvimento; é dele que saem a extensão assinada e o perfil com a permissão de
#    instalar extensões de sistema.
# 2. scripts/build-app.sh monta o bmonitor normal.
# 3. Aqui o bmonitor ganha outro bundle id, a extensão, o perfil e a assinatura de desenvolvimento.
#
# A extensão só ativa com o app em /Applications. Na primeira vez, o macOS pede aprovação em
# Ajustes do Sistema › Geral › Itens de Início e Extensões › Extensões de Câmera.
set -euo pipefail
cd "$(dirname "$0")/.."

DD="${DERIVED_DATA:-$PWD/.build/webcam-dd}"
HOST="$DD/Build/Products/Debug/Host.app"
DEV=".build/dev/bmonitor Dev.app"
IDENTITY="Apple Development"

(cd Webcam && BASE_ID=com.dantearaujo.bmonitor.dev xcodegen generate >/dev/null)
xcodebuild -project Webcam/Webcam.xcodeproj -scheme Host -configuration Debug -derivedDataPath "$DD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >/dev/null

# Versão alta: o Sparkle nunca oferece a release no lugar do protótipo.
VERSION=9.9.9 scripts/build-app.sh >/dev/null

rm -rf "$DEV"
mkdir -p "$(dirname "$DEV")"
ditto .build/dist/bmonitor.app "$DEV"
PLIST="$DEV/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.dantearaujo.bmonitor.dev "$PLIST"
plutil -replace CFBundleName -string "bmonitor Dev" "$PLIST"
plutil -replace CFBundleDisplayName -string "bmonitor Dev" "$PLIST"
plutil -replace NSCameraUsageDescription -string "O bmonitor entrega o vídeo do iPhone à câmera virtual bmonitor." "$PLIST"

mkdir -p "$DEV/Contents/Library/SystemExtensions"
ditto "$HOST/Contents/Library/SystemExtensions" "$DEV/Contents/Library/SystemExtensions"
cp "$HOST/Contents/embedded.provisionprofile" "$DEV/Contents/embedded.provisionprofile"
codesign -d --entitlements - --xml "$HOST" > .build/dev/host.entitlements 2>/dev/null

# Assinatura de dentro para fora; a extensão já vem assinada pelo Xcode e não é tocada.
SIGN=(codesign --force --options runtime --sign "$IDENTITY")
FW="$DEV/Contents/Frameworks"
for f in "$FW"/*.dylib; do "${SIGN[@]}" "$f"; done
SP="$FW/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SP/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SP/Autoupdate"
"${SIGN[@]}" "$SP/Updater.app"
"${SIGN[@]}" "$FW/Sparkle.framework"
"${SIGN[@]}" --entitlements .build/dev/host.entitlements "$DEV"
codesign --verify --deep --strict "$DEV"

rm -rf "/Applications/bmonitor Dev.app"
ditto "$DEV" "/Applications/bmonitor Dev.app"
echo "instalado: /Applications/bmonitor Dev.app"
