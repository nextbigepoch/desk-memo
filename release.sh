#!/bin/zsh
# 打包发布版：同时支持 Apple 芯片和 Intel 的通用 App，输出到 dist/
#   dist/桌面备忘-<版本>.dmg   ← 发给别人用这个
#   dist/桌面备忘-<版本>.zip
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="dist/桌面备忘.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

for arch in arm64 x86_64; do
  echo "编译 $arch…"
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 -parse-as-library \
    Sources/*.swift -o dist/DeskMemo-$arch
done
lipo -create dist/DeskMemo-arm64 dist/DeskMemo-x86_64 -output "$APP/Contents/MacOS/DeskMemo"
rm dist/DeskMemo-arm64 dist/DeskMemo-x86_64
codesign --force -s - -r '=designated => identifier "com.cox.deskmemo"' "$APP"

# DMG：打开后把 App 拖到「应用程序」即可
STAGE=dist/dmg
mkdir -p $STAGE
cp -R "$APP" $STAGE/
ln -s /Applications $STAGE/应用程序
cp docs/打不开怎么办.txt $STAGE/
hdiutil create -quiet -volname "桌面备忘 $VERSION" -srcfolder $STAGE -ov -format UDZO "dist/桌面备忘-$VERSION.dmg"
rm -rf $STAGE

ditto -c -k --keepParent "$APP" "dist/桌面备忘-$VERSION.zip"
echo "完成："
ls -lh dist/*.dmg dist/*.zip
