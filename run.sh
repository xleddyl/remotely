#!/bin/zsh
# Start the Mac sender app. It listens on :9000 and advertises itself on the
# local network; open Remotely on the iPhone or iPad and pick this Mac from the
# list (or type its address) to start streaming.
set -e
cd "$(dirname "$0")"

APP=build/Build/Products/Debug/Remotely.app
if [[ ! -d $APP ]]; then
  echo "Mac app not built. Run: xcodegen generate && xcodebuild -project Remotely.xcodeproj -scheme RemotelyMac -configuration Debug -derivedDataPath build build"
  exit 1
fi

open "$APP"
echo "Remotely running. Logs at ~/Library/Logs/Remotely/remotely.log."
