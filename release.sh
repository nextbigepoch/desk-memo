#!/bin/zsh
# 打包发布版：同时支持 Apple 芯片和 Intel 的通用 App，输出到 dist/
#   dist/DeskMemo-<版本>.dmg   ← 发给别人用这个
#   dist/DeskMemo-<版本>.zip
#   dist/DeskMemo-source.zip    ← 上传 GitHub 仓库用的源码
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
ln -s /Applications $STAGE/Applications
cp docs/How-to-install.txt $STAGE/
hdiutil create -quiet -volname "DeskMemo $VERSION" -srcfolder $STAGE -ov -format UDZO "dist/DeskMemo-$VERSION.dmg"
rm -rf $STAGE

ditto -c -k --keepParent "$APP" "dist/DeskMemo-$VERSION.zip"
# 源码包（不含编译产物）
SRC=$(mktemp -d)
rsync -a --exclude build --exclude dist --exclude .DS_Store --exclude .git ./ "$SRC/desk-memo/"
ditto -c -k --norsrc --noextattr --keepParent "$SRC/desk-memo" dist/DeskMemo-source.zip
rm -rf "$SRC"

echo "完成："
ls -lh dist/*.dmg dist/*.zip
