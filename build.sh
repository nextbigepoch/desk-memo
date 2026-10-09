#!/bin/zsh
# 编译并安装到 ~/Applications/桌面备忘.app，然后重启它
set -e
cd "$(dirname "$0")"
APP="build/桌面备忘.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  Sources/*.swift -o "$APP/Contents/MacOS/DeskMemo"
# 固定签名身份：以后每次更新，系统都认得是同一个 App，不会重复弹权限
codesign --force -s - -r '=designated => identifier "com.cox.deskmemo"' "$APP"
[[ "$1" == "--no-install" ]] && exit 0
pkill -x DeskMemo 2>/dev/null && sleep 0.5 || true
rm -rf ~/Applications/桌面备忘.app
cp -R "$APP" ~/Applications/
touch ~/Applications/桌面备忘.app   # 让访达刷新图标缓存
open ~/Applications/桌面备忘.app
echo "已安装并启动：~/Applications/桌面备忘.app"
