# Remotely

Turn an iPhone or iPad into an extra display for your Mac, over WiFi or any
network you can reach the Mac on (Tailscale, VPN).

Remotely streams your Mac's screen to your device and sends touch, trackpad,
keyboard, and Apple Pencil input back to the Mac. The iPad can act as a
regular touch display, a trackpad, or (on the Mac side) as the system's main
display.

## Requirements

- macOS 14 or later
- iOS 16.4 or later

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml`, so it is not committed.

```sh
xcodegen generate
```

This produces `Remotely.xcodeproj` with two schemes, `RemotelyMac` and
`RemotelyiOS`. Open the project in Xcode and build both, or use `xcodebuild`
directly:

```sh
xcodebuild build -project Remotely.xcodeproj -scheme RemotelyMac -destination 'platform=macOS'
xcodebuild build -project Remotely.xcodeproj -scheme RemotelyiOS -destination 'generic/platform=iOS'
```

## Running

The device decides, the Mac only waits:

1. Open Remotely on the Mac. It starts listening on port 9000 and advertises
   itself on the local network. Nothing to click.
2. Open Remotely on the iPhone or iPad.
3. Pick the Mac from the list and tap Connect. Away from home, use "Connect by
   address" with the Mac's Tailscale or VPN address instead.

After the first connection the device remembers that Mac and reconnects on its
own whenever you come back to the app. Turn that off with "Reconnect
automatically" in the app's settings.

The device always becomes the Mac's main display: the menu bar, Dock and new
windows move onto it, and the Mac's own screens go black until you disconnect.
The streaming quality lives on the device too, under Settings > Streaming in
the iPhone or iPad app. The device pushes it to the Mac as soon as it connects,
so the Mac panel has nothing to set.

## License

Remotely is licensed under the GNU General Public License v3.0. See
[LICENSE](LICENSE) for the full text.

This project originated as a fork of the OpenDisplay project.
