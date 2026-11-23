#!/bin/sh
# Builds TheGrid.app.
#
# An app bundle rather than the bare binary because macOS hangs Accessibility permission on an
# app: run from Terminal, the permission would land on Terminal instead, and every terminal on
# the machine could then move windows. Signed ad hoc, which is enough to run it here.
#
# The permission is remembered per signature, so after a rebuild macOS may want it granted again:
# untick and retick TheGrid in Privacy & Security > Accessibility if the grid stops moving
# windows after a build.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product TheGrid
APP="dist/TheGrid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TheGrid "$APP/Contents/MacOS/TheGrid"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.thegrid.app</string>
	<key>CFBundleName</key>
	<string>TheGrid</string>
	<key>CFBundleDisplayName</key>
	<string>TheGrid</string>
	<key>CFBundleExecutable</key>
	<string>TheGrid</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<!-- A menu bar app: no Dock icon, no window of its own. -->
	<key>LSUIElement</key>
	<true/>
</dict>
PLIST
printf '</plist>\n' >> "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"

# Zipped with ditto rather than zip, which keeps the bundle's structure intact: what comes out
# the other end of a download is still an app.
(cd dist && rm -f TheGrid.zip && ditto -c -k --keepParent TheGrid.app TheGrid.zip)
echo "built $APP and dist/TheGrid.zip"
