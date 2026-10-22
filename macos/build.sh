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
    RW="build/dmg-rw.dmg"
    BG="build/dmgbg"

    if [ ! -f "$BG/background.tiff" ] || [ scripts/make-dmg-background.swift -nt "$BG/background.tiff" ]; then
        echo "→ a gerar o fundo do instalador"
        mkdir -p "$BG"
        swift scripts/make-dmg-background.swift "$BG"
        # TIFF com 1x e 2x: o Finder escolhe a resolução certa no ecrã Retina.
        tiffutil -cathidpicheck "$BG/background.png" "$BG/background@2x.png" -out "$BG/background.tiff" 2>/dev/null
    fi

    echo "→ a montar $DMG"
    rm -rf "$STAGING" "$DMG" "$RW"
    mkdir -p "$STAGING/.background"
    cp -R "$APP" "$STAGING/"
    # Atalho para arrastar a app para Aplicações.
    ln -s /Applications "$STAGING/Applications"
    cp "$BG/background.tiff" "$STAGING/.background/background.tiff"

    # Imagem gravável primeiro, para o Finder guardar o layout da janela no .DS_Store do volume.
    hdiutil detach -quiet "/Volumes/$APP_NAME" 2>/dev/null || true
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW"
    MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" 2>/dev/null | grep -o '/Volumes/.*$')"
    VOLNAME="$(basename "$MOUNT")"

    # Posições (170,215) e (490,215) batem com os "pousos" desenhados no fundo.
    if ! osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 540}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {170, 215}
        set position of item "Applications" of container window to {490, 215}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    then
        echo "⚠ o Finder não aceitou o layout (permissão de Automação?); o .dmg sai sem janela personalizada"
    fi

    # Ícone do volume: o -srcfolder descarta .VolumeIcon.icns e o Finder apaga-o se for antes do layout.
    cp "$ICNS" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
    rm -rf "$MOUNT/.fseventsd"
    sync
    hdiutil detach -quiet "$MOUNT"
    hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -rf "$STAGING" "$RW"
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
