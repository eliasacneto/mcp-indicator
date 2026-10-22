#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
UUID="mcp-indicator@rodriguesfas.github.io"
DEST="${HOME}/.local/share/gnome-shell/extensions/${UUID}"

glib-compile-schemas "${ROOT}/schemas"
mkdir -p "$(dirname "${DEST}")"
ln -sfn "${ROOT}" "${DEST}"

echo "Instalado: ${DEST} → ${ROOT}"
echo
echo "No X11: Alt+F2, digite r, Enter, e depois:"
echo "  gnome-extensions enable ${UUID}"
echo
echo "No Wayland: faça logout/login e então o mesmo gnome-extensions enable."
