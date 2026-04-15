#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/iosApp"
OUT_DIR="$ROOT_DIR/build/ios"
APP_NAME="OuterTuneiOS"
SCHEME="$APP_NAME"
PROJECT="$IOS_DIR/$APP_NAME.xcodeproj"
MODE="${1:-adhoc}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi

mkdir -p "$OUT_DIR"

xcodegen generate --spec "$IOS_DIR/project.yml"

case "$MODE" in
  signed)
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Release \
      -destination generic/platform=iOS \
      -archivePath "$OUT_DIR/$APP_NAME.xcarchive" \
      archive \
      -allowProvisioningUpdates

    xcodebuild \
      -exportArchive \
      -archivePath "$OUT_DIR/$APP_NAME.xcarchive" \
      -exportPath "$OUT_DIR/export" \
      -exportOptionsPlist "$IOS_DIR/ExportOptions.plist" \
      -allowProvisioningUpdates

    echo "Signed IPA: $OUT_DIR/export/$APP_NAME.ipa"
    ;;

  unsigned|adhoc)
    xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Release \
      -sdk iphoneos \
      -derivedDataPath "$OUT_DIR/DerivedData" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      build

    APP_PATH="$OUT_DIR/DerivedData/Build/Products/Release-iphoneos/$APP_NAME.app"

    if [[ "$MODE" == "adhoc" ]]; then
      codesign --force --sign - --deep --timestamp=none "$APP_PATH"
    fi

    rm -rf "$OUT_DIR/Payload"
    mkdir -p "$OUT_DIR/Payload"
    cp -R "$APP_PATH" "$OUT_DIR/Payload/"

    IPA_PATH="$OUT_DIR/$APP_NAME-$MODE.ipa"
    (
      cd "$OUT_DIR"
      /usr/bin/zip -qry "$(basename "$IPA_PATH")" Payload
    )

    echo "IPA: $IPA_PATH"
    ;;

  *)
    echo "Usage: $0 [adhoc|unsigned|signed]"
    exit 1
    ;;
esac
