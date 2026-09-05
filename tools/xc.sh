#!/bin/bash
# Build "Autographe for Xcode" and assemble it into a .app bundle.
#
#   tools/xc.sh build      swift build only
#   tools/xc.sh bundle     build + assemble the .app
#   tools/xc.sh run        bundle + launch (kills a running copy first)
#   tools/xc.sh stop       quit a running copy
#   tools/xc.sh logs       stream the app's os_log output
#
# The bundle is assembled rather than built by Xcode because SwiftPM cannot produce one.
# It matters for more than tidiness: TCC keys an Accessibility grant to a *code signature*,
# so a stable bundle identity signed the same way each time keeps the permission across
# rebuilds. A bare executable would ask again every time.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${XC_CONFIG:-debug}"
APP_NAME="Autographe for Xcode"
BUNDLE_ID="com.wassimans.AutographeForXcode"
# Kept out of ~/Documents on purpose: building under it attaches extended attributes that
# make codesign fail with "resource fork, Finder information, or similar detritus".
BUILD_ROOT="${XC_BUILD_ROOT:-$HOME/Library/Caches/AutographeForXcode}"
BUNDLE="$BUILD_ROOT/$APP_NAME.app"

build() {
  swift build -c "$CONFIG" --scratch-path "$BUILD_ROOT/.build"
}

bundle() {
  build
  local bin
  bin="$BUILD_ROOT/.build/$CONFIG/Companion"
  [ -x "$bin" ] || { echo "no binary at $bin"; exit 1; }

  mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
  cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- A menu-bar app: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
</dict>
</plist>
PLIST
  cp "$bin" "$BUNDLE/Contents/MacOS/Companion"

  # SwiftPM does not build asset catalogues, so do it by hand with the same tool Xcode
  # uses. It matters for more than the menu-bar mark: an app with no icon shows the generic
  # placeholder in the "would like to control this computer" prompt, which is the worst
  # possible answer to "do I trust this?".
  actool "Sources/Companion/Assets.xcassets" \
    --compile "$BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_ROOT/assets-partial.plist" \
    --output-format human-readable-text >/dev/null

  xattr -cr "$BUNDLE" 2>/dev/null || true
  # Ad-hoc signing is enough locally, but the *identity* changes on every rebuild, which is
  # what makes macOS forget the Accessibility grant. Sign with a real certificate when one
  # is available so the grant sticks.
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    local id
    id=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
    codesign --force --sign "$id" --options runtime --timestamp=none "$BUNDLE" >/dev/null
    echo "signed with Apple Development ($id)"
  else
    codesign --force --sign - "$BUNDLE" >/dev/null
    echo "ad-hoc signed (Accessibility permission will be asked for again after each rebuild)"
  fi
  echo "$BUNDLE"
}

stop() { osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
         pkill -x Companion >/dev/null 2>&1 || true; }

case "${1:-bundle}" in
  build)  build ;;
  bundle) bundle ;;
  run)    stop; bundle; open "$BUNDLE"; echo "launched" ;;
  stop)   stop; echo "stopped" ;;
  logs)   log stream --predicate "subsystem == \"$BUNDLE_ID\"" --level debug ;;
  *)      echo "usage: tools/xc.sh [build|bundle|run|stop|logs]"; exit 1 ;;
esac
