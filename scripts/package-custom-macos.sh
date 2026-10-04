#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then echo 'This package script requires macOS.' >&2; exit 1; fi
build_dir=${1:-build-release}
build_dir=$(CDPATH= cd -- "$build_dir" && pwd)
app="$build_dir/TreX.app"
stage=$(mktemp -d "$build_dir/custom-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
meson install -C "$build_dir" --destdir "$stage/install" --skip-subprojects
if [ ! -x "$stage/install/lite-xl" ]; then
  echo 'Configure this build with -Dportable=true -Dbundle=false first.' >&2; exit 1
fi
bundle="$stage/TreX.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$stage/install/lite-xl" "$bundle/Contents/MacOS/lite-xl"
cp -R "$stage/install/data" "$bundle/Contents/Resources/data"
ln -s ../Resources/data "$bundle/Contents/MacOS/data"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>lite-xl</string>
<key>CFBundleIdentifier</key><string>com.trex.editor</string>
<key>CFBundleName</key><string>TreX</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
if [ -e "$app" ]; then mv "$app" "$stage/previous.app"; fi
mv "$bundle" "$app"
printf 'Built %s\n' "$app"
