#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/dist}"
build_dir="${CLIPSHELF_BUILD_DIR:-$project_dir/.build}"
signing_identity="E6124AB6C7079D7F1E764992CA61167210660010"
signing_requirement="identifier \"local.clipshelf.app\" and certificate leaf = H\"$signing_identity\""
if ! security find-identity -v -p codesigning | grep -Fq "$signing_identity"; then
    echo "ClipShelf Release Signing certificate and private key are required; see signing/README.md." >&2
    exit 1
fi
mkdir -p "$output_dir"
swift build --package-path "$project_dir" -c release --scratch-path "$build_dir"
binary_dir="$(swift build --package-path "$project_dir" -c release --scratch-path "$build_dir" --show-bin-path)"
app_dir="$output_dir/ClipShelf.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/ClipShelf" "$app_dir/Contents/MacOS/ClipShelf"
cp "$project_dir/Assets/ClipShelf.icns" "$app_dir/Contents/Resources/ClipShelf.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClipShelf</string>
<key>CFBundleIdentifier</key><string>local.clipshelf.app</string>
<key>CFBundleName</key><string>ClipShelf</string>
<key>CFBundleDisplayName</key><string>ClipShelf</string>
<key>CFBundleIconFile</key><string>ClipShelf</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.10.2</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$signing_identity" --timestamp=none --requirements "=designated => $signing_requirement" "$app_dir"
codesign --verify --deep --strict --test-requirement "=$signing_requirement" "$app_dir"
printf '%s\n' "Built: $app_dir"
