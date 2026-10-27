#!/bin/sh
# ./build.sh          build build/Sweep.app
# ./build.sh install  also copy to ~/Applications and register the Finder service
set -eu
cd "$(dirname "$0")"
APP=build/Sweep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
# Format and lint on every local build, as Reader does; lint errors fail the build. NOLINT: Homebrew's build skips both.
if [ -z "${NOLINT:-}" ]; then
  if command -v swiftformat > /dev/null; then swiftformat --quiet .; fi
  if command -v swiftlint > /dev/null; then swiftlint --quiet; fi
fi
# SWIFTFLAGS: Homebrew passes -disable-sandbox, since swiftc's macro sandbox can't nest inside brew's.
swiftc -O ${SWIFTFLAGS:-} Sources/*.swift -o "$APP/Contents/MacOS/Sweep"
# Emits Assets.car (Liquid Glass icon, macOS 26+) and AppIcon.icns (older systems). actool ships with Xcode only;
# without it (Command Line Tools, e.g. Homebrew) use the committed AppIcon.icns, built from an ictool render.
mkdir -p "$APP/Contents/Resources"
if xcrun -f actool > /dev/null 2>&1; then
  xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist build/icon-info.plist > /dev/null
else
  cp AppIcon.icns "$APP/Contents/Resources/"
fi
# A real identity keeps privacy grants (App Management, Full Disk Access) across rebuilds; ad-hoc ones reset.
codesign -s "${SIGN_ID:--}" --force "$APP"
if [ "${1:-}" = install ]; then
  pkill -x Sweep || true
  rm -rf ~/Applications/Sweep.app
  ditto "$APP" ~/Applications/Sweep.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Sweep.app
  /System/Library/CoreServices/pbs -update
  open ~/Applications/Sweep.app
fi
