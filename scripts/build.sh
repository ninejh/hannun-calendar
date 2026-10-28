#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'This build supports Apple silicon (arm64) only.'; exit 1; }
mkdir -p build
[[ ! -e 'build/Hannun Calendar.app' ]] || { print -u2 'Remove or move the existing build/Hannun Calendar.app first.'; exit 1; }
stage=$(mktemp -d build/stage.XXXXXXXX)
trap 'rm -rf -- "$stage"' EXIT
python3 scripts/attest.py before "$stage/inputs.json"
app="$stage/Hannun Calendar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/module-cache"
# Relative source paths avoid embedding the checkout location in #filePath.
sources=(Sources/**/*.swift(N.))
(( ${#sources} > 0 )) || { print -u2 'No Swift sources found.'; exit 1; }
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -O -j 3 \
  -target arm64-apple-macosx14.0 -module-cache-path "$stage/module-cache" \
  -framework AppKit -framework EventKit -framework Combine -framework ServiceManagement \
  -framework UserNotifications "${sources[@]}" -o "$app/Contents/MacOS/HannunCalendar"
xcrun strip -S "$app/Contents/MacOS/HannunCalendar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/{AppIcon.icns,Cities.json,Strings.json} LICENSE "$app/Contents/Resources/"
codesign --force --sign - --entitlements Resources/HannunCalendar.entitlements "$app"
codesign --verify --strict "$app"
mv "$app" 'build/Hannun Calendar.app'
python3 scripts/attest.py after "$stage/inputs.json"
print 'Built build/Hannun Calendar.app (ad hoc signed, not notarized).'
