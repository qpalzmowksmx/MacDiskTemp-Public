#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"

swift build -c release --product MacDiskTemp --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" \
    -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_ROOT=/MacDiskTemp" \
    -Xswiftc -gnone
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache")"
APP="$PROJECT_ROOT/dist/MacDiskTemp.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacDiskTemp" "$APP/Contents/MacOS/MacDiskTemp"
# Release binaries must not reveal the developer's home directory in debug symbols.
strip -S "$APP/Contents/MacOS/MacDiskTemp"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
swift "$PROJECT_ROOT/Scripts/GenerateIcon.swift" "$PROJECT_ROOT/.build/AppIcon.iconset"
iconutil -c icns "$PROJECT_ROOT/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_ARCH="$(lipo -archs "$APP/Contents/MacOS/MacDiskTemp" | tr ' ' '-')"
PACKAGE_NAME="MacDiskTemp-$APP_VERSION-$APP_ARCH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$PROJECT_ROOT/dist/$PACKAGE_NAME.zip"

DMG_STAGE="$(mktemp -d "$PROJECT_ROOT/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP" "$DMG_STAGE/MacDiskTemp.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp "$PROJECT_ROOT/LICENSE" "$DMG_STAGE/LICENSE.txt"
cat > "$DMG_STAGE/설치 안내.txt" <<'INSTALL'
MacDiskTemp 설치

1. MacDiskTemp.app을 Applications로 끌어다 놓습니다.
2. 응용 프로그램 폴더에서 MacDiskTemp를 실행합니다.
3. smartmontools가 없으면 앱의 자동 설치 안내를 따릅니다.

이 배포본을 실행하기 위해 앱을 직접 빌드할 필요는 없습니다.
macOS 13 이상이 필요하며, 파일명의 CPU 종류에 맞는 Mac에서 사용하세요.
이 앱은 임시 서명(ad-hoc) 상태이며 Apple Developer ID 서명·공증을 받지 않았습니다.
다운로드한 앱이 차단되면 출처를 확인한 후 macOS의 개인정보 보호 및 보안 안내를 따르세요.

앱을 지워도 Homebrew와 smartmontools는 남습니다.
측정 화면이나 SMART 원문을 공유할 때는 디스크 일련번호를 확인하세요.
INSTALL
hdiutil create -ov -volname MacDiskTemp -srcfolder "$DMG_STAGE" \
    -fs HFS+ -format UDZO -nospotlight \
    "$PROJECT_ROOT/dist/$PACKAGE_NAME.dmg"
hdiutil verify "$PROJECT_ROOT/dist/$PACKAGE_NAME.dmg"
(
    cd "$PROJECT_ROOT/dist"
    shasum -a 256 "$PACKAGE_NAME.zip" "$PACKAGE_NAME.dmg" > SHA256SUMS.txt
)
printf '\n앱 생성 완료: %s\nZIP: %s\nDMG: %s\n' \
    "$APP" "$PROJECT_ROOT/dist/$PACKAGE_NAME.zip" "$PROJECT_ROOT/dist/$PACKAGE_NAME.dmg"
