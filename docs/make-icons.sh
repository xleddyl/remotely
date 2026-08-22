#!/bin/zsh
set -e

cd "$(dirname "$0")/.."

IOS_DIR=iOS/Assets.xcassets/AppIcon.appiconset
MAC_DIR=Mac/Assets.xcassets/AppIcon.appiconset

typeset -a ios_icons
ios_icons=(
  "icon_20@2x.png 40"
  "icon_20@3x.png 60"
  "icon_29@2x.png 58"
  "icon_29@3x.png 87"
  "icon_40@2x.png 80"
  "icon_40@3x.png 120"
  "icon_60@2x.png 120"
  "icon_60@3x.png 180"
  "ipad_20@1x.png 20"
  "ipad_20@2x.png 40"
  "ipad_29@1x.png 29"
  "ipad_29@2x.png 58"
  "ipad_40@1x.png 40"
  "ipad_40@2x.png 80"
  "ipad_76@1x.png 76"
  "ipad_76@2x.png 152"
  "ipad_83@2x.png 167"
  "icon-1024.png 1024"
)

for pair in $ios_icons; do
  name="${pair%% *}"
  size="${pair##* }"
  /opt/homebrew/bin/inkscape docs/icon-ios.svg -w $size -h $size -o "$IOS_DIR/$name"
done

sips -s format jpeg "$IOS_DIR/icon-1024.png" --out /tmp/icon1024.jpg
sips -s format png /tmp/icon1024.jpg --out "$IOS_DIR/icon-1024.png"
rm /tmp/icon1024.jpg

/opt/homebrew/bin/inkscape docs/icon-ios.svg -w 640 -h 640 -o iOS/Assets.xcassets/AppLogo.imageset/applogo.png

typeset -a mac_icons
mac_icons=(
  "icon_16.png 16"
  "icon_32.png 32"
  "icon_64.png 64"
  "icon_128.png 128"
  "icon_256.png 256"
  "icon_512.png 512"
  "icon_1024.png 1024"
)

for pair in $mac_icons; do
  name="${pair%% *}"
  size="${pair##* }"
  /opt/homebrew/bin/inkscape docs/icon-mac.svg -w $size -h $size -o "$MAC_DIR/$name"
done

MENUBAR_DIR=Mac/Assets.xcassets/MenuBarIcon.imageset
MENUBAR_FILL_DIR=Mac/Assets.xcassets/MenuBarIconFill.imageset

/opt/homebrew/bin/inkscape docs/mark-menubar.svg -w 16 -h 16 -o "$MENUBAR_DIR/menubar_16.png"
/opt/homebrew/bin/inkscape docs/mark-menubar.svg -w 32 -h 32 -o "$MENUBAR_DIR/menubar_32.png"
/opt/homebrew/bin/inkscape docs/mark-menubar-fill.svg -w 16 -h 16 -o "$MENUBAR_FILL_DIR/menubar_16.png"
/opt/homebrew/bin/inkscape docs/mark-menubar-fill.svg -w 32 -h 32 -o "$MENUBAR_FILL_DIR/menubar_32.png"
