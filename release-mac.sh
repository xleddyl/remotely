#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Checking for Developer ID Application certificate"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo 'Missing "Developer ID Application" certificate. Create it in Xcode > Settings > Accounts > Manage Certificates.'
  exit 1
fi

echo "==> Checking notarytool keychain profile"
if ! xcrun notarytool history --keychain-profile remotely-notary >/dev/null 2>&1; then
  echo 'Missing notary profile. Run: xcrun notarytool store-credentials remotely-notary --apple-id <apple-id> --team-id JV946Y56W6 --password <app-specific-password>'
  exit 1
fi

echo "==> Checking gh CLI and auth status"
if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found. Install it and run: gh auth login"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login"
  exit 1
fi

echo "==> Checking for uncommitted changes"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes, commit or stash first."
  exit 1
fi

echo "==> Reading MARKETING_VERSION from project.yml"
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/[^0-9.]//g')
if [[ -z "$VERSION" ]]; then
  echo "Could not determine MARKETING_VERSION from project.yml."
  exit 1
fi
TAG="v$VERSION"
echo "Version: $VERSION (tag: $TAG)"

echo "==> Checking whether release $TAG already exists"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists. Bump MARKETING_VERSION in project.yml first."
  exit 1
fi

echo "==> Generating Xcode project"
DEVELOPMENT_TEAM=JV946Y56W6 xcodegen generate

echo "==> Preparing dist directory"
DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST"

if ! grep -qx 'dist/' .gitignore 2>/dev/null; then
  echo "dist/" >> .gitignore
fi

echo "==> Archiving RemotelyMac (Release)"
xcodebuild archive \
  -project Remotely.xcodeproj \
  -scheme RemotelyMac \
  -configuration Release \
  -archivePath "$DIST/Remotely.xcarchive" \
  | tail -n 40

echo "==> Writing export options plist"
cat > "$DIST/export-options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>JV946Y56W6</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF

echo "==> Exporting archive"
xcodebuild -exportArchive \
  -archivePath "$DIST/Remotely.xcarchive" \
  -exportOptionsPlist "$DIST/export-options.plist" \
  -exportPath "$DIST/export" \
  -allowProvisioningUpdates \
  | tail -n 40

APP="$DIST/export/Remotely.app"

echo "==> Zipping app for notarization"
ditto -c -k --keepParent "$APP" "$DIST/Remotely.zip"

echo "==> Submitting for notarization"
if ! xcrun notarytool submit "$DIST/Remotely.zip" --keychain-profile remotely-notary --wait; then
  echo "Notarization submission failed. See log above."
  exit 1
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"

echo "==> Creating DMG"
DMG="$DIST/Remotely-$VERSION.dmg"
hdiutil create -volname Remotely -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$DMG" --title "Remotely $VERSION" --generate-notes

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo "==> Release published: $RELEASE_URL"
