#!/bin/zsh
# Compila a libsrt e o OpenSSL a partir do código-fonte para o app empacotado: binário
# universal (arm64 e x86_64) com macOS 14 como mínimo. As bibliotecas do Homebrew servem
# só para a máquina em que foram instaladas (minos = versão do macOS dela).
# Resultado em .build/deps/universal (lib, include, lib/pkgconfig), com nomes @rpath.
# Uso: scripts/build-deps.sh   (requer cmake; leva alguns minutos na primeira vez)
set -euo pipefail
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=14.0
OPENSSL_VERSION=4.0.3
OPENSSL_SHA=325b5c806167c13b40b1ffeadfe0248197c00eccc4cf123ec1e28d2d2fd216d9
SRT_VERSION=1.5.7
SRT_SHA=017cd1e437ef2073a4dd10ddf7b55e86bc3d6ebac0393d13bd22f6a57055d32b
DEPS="$PWD/.build/deps"
SRC="$DEPS/src"
JOBS=$(sysctl -n hw.ncpu)

if [[ -f "$DEPS/universal/.done-$OPENSSL_VERSION-$SRT_VERSION" ]]; then
    echo "dependências já compiladas em $DEPS/universal"
    exit 0
fi

fetch() {  # fetch <url> <sha256> <arquivo>
    [[ -f "$SRC/$3" ]] || curl -sSL -o "$SRC/$3" "$1"
    echo "$2  $SRC/$3" | shasum -a 256 -c - >/dev/null || { echo "checksum errado: $3" >&2; exit 1; }
}

mkdir -p "$SRC"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$OPENSSL_SHA" "openssl-$OPENSSL_VERSION.tar.gz"
fetch "https://github.com/Haivision/srt/archive/refs/tags/v$SRT_VERSION.tar.gz" "$SRT_SHA" "srt-$SRT_VERSION.tar.gz"

for ARCH in arm64 x86_64; do
    PREFIX="$DEPS/$ARCH"
    rm -rf "$PREFIX" "$SRC/build-$ARCH"
    mkdir -p "$SRC/build-$ARCH"

    echo "OpenSSL $OPENSSL_VERSION ($ARCH)…"
    tar -xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$SRC/build-$ARCH"
    (
        cd "$SRC/build-$ARCH/openssl-$OPENSSL_VERSION"
        ./Configure "darwin64-$ARCH-cc" shared no-tests no-docs --prefix="$PREFIX" --libdir=lib >/dev/null
        make -j"$JOBS" build_libs >/dev/null
        make install_dev >/dev/null
    )

    echo "SRT $SRT_VERSION ($ARCH)…"
    # Só o OpenSSL desta arquitetura: sem isso o cmake acha o do Homebrew (arm64, macOS atual).
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=""
    tar -xzf "$SRC/srt-$SRT_VERSION.tar.gz" -C "$SRC/build-$ARCH"
    cmake -S "$SRC/build-$ARCH/srt-$SRT_VERSION" -B "$SRC/build-$ARCH/srt-build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DENABLE_APPS=OFF -DENABLE_STATIC=OFF -DENABLE_SHARED=ON \
        -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=OFF \
        -DOPENSSL_INCLUDE_DIR="$PREFIX/include" -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.dylib" \
        -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.dylib" -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew >/dev/null
    cmake --build "$SRC/build-$ARCH/srt-build" -j"$JOBS" >/dev/null
    cmake --install "$SRC/build-$ARCH/srt-build" >/dev/null

    # Nomes @rpath, para o app achar as bibliotecas em Contents/Frameworks.
    for lib in libcrypto.4.dylib libssl.4.dylib libsrt.1.5.dylib; do
        f="$PREFIX/lib/$lib"
        chmod u+w "$f"
        install_name_tool -id "@rpath/$lib" "$f" 2>/dev/null
        for ref in $(otool -L "$f" | awk 'NR>1{print $1}' | grep -E "libssl|libcrypto" | grep -v "^@rpath" || true); do
            install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$f" 2>/dev/null
        done
    done
done

echo "universal…"
U="$DEPS/universal"
rm -rf "$U"
mkdir -p "$U/lib/pkgconfig"
cp -R "$DEPS/arm64/include" "$U/include"
for lib in libcrypto.4.dylib libssl.4.dylib libsrt.1.5.dylib; do
    lipo -create "$DEPS/arm64/lib/$lib" "$DEPS/x86_64/lib/$lib" -output "$U/lib/$lib"
done
ln -sf libsrt.1.5.dylib "$U/lib/libsrt.dylib"
ln -sf libssl.4.dylib "$U/lib/libssl.dylib"
ln -sf libcrypto.4.dylib "$U/lib/libcrypto.dylib"
for pc in "$DEPS/arm64/lib/pkgconfig/"*.pc; do
    sed "s#$DEPS/arm64#$U#g" "$pc" > "$U/lib/pkgconfig/$(basename "$pc")"
done
touch "$U/.done-$OPENSSL_VERSION-$SRT_VERSION"

for lib in "$U"/lib/*.4.dylib "$U"/lib/libsrt.1.5.dylib; do
    printf '%s: %s, minos %s\n' "$(basename "$lib")" "$(lipo -archs "$lib")" \
        "$(otool -l "$lib" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
done
