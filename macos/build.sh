#!/usr/bin/env bash
# Compila o MCP Indicator para Apple Silicon e monta "build/MCP Indicator.app".
#   ./build.sh            só compila e empacota
#   ./build.sh --install  copia para ~/Applications e abre
#   ./build.sh --dmg      gera também build/MCP-Indicator-<versão>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MCP Indicator"
EXECUTABLE="MCPIndicator"
APP="build/$APP_NAME.app"

# Scratch path próprio: um build release com --arch partilhando .build estraga o cache do `swift test`.
SWIFT_FLAGS=(-c release --arch arm64 --scratch-path .build/app)
echo "→ swift build (release, arm64)"
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/$EXECUTABLE"

echo "→ a montar $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICNS="build/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ scripts/make-icon.swift -nt "$ICNS" ]; then
    echo "→ a gerar o ícone"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift scripts/make-icon.swift build/AppIcon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "→ assinatura ad-hoc"
codesign --force --sign - --timestamp=none "$APP"

if [ "${1:-}" = "--dmg" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    DMG="build/MCP-Indicator-$VERSION-arm64.dmg"
    STAGING="build/dmg"
    echo "→ a montar $DMG"
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    # Atalho para arrastar a app para Aplicações.
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
    rm -rf "$STAGING"
    echo "✓ $DMG"
elif [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    echo "→ instalado em $DEST/$APP_NAME.app"
    open "$DEST/$APP_NAME.app"
else
    echo "✓ $APP"
fi
