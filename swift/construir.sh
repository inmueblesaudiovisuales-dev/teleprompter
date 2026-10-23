#!/bin/bash
# Arma Teleprompter.app (versión Swift) en swift/build/.
# La pantalla es la misma de siempre: se copia de app/pantalla.html, que es la única fuente.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Teleprompter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  Fuentes/main.swift Fuentes/Servidor.swift \
  -o "$APP/Contents/MacOS/Teleprompter"

cp Info.plist "$APP/Contents/Info.plist"
cp ../app/pantalla.html "$APP/Contents/Resources/pantalla.html"

# Firma local (sin cuenta de Apple): basta para abrirla en esta Mac y en otras con clic derecho → Abrir.
codesign --force --deep -s - "$APP"
echo "listo: $APP ($(du -sh "$APP" | cut -f1))"
