#!/bin/zsh
# 司法試験カウントダウンのビルドスクリプト
# 使い方: ~/ShihouCountdown/build.sh
set -e
SRC="$HOME/ShihouCountdown"
APP="$HOME/Applications/ShihouCountdown.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O "$SRC/main.swift" -o "$APP/Contents/MacOS/ShihouCountdown"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "Built: $APP"
