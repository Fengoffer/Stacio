#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SWIFT_COMPILER="${STACIO_TEST_SWIFTC:-$(xcrun --find swiftc)}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

# A packaged app must never evaluate SwiftPM's developer-only bundle accessor.
# This sentinel makes the test fail even on a machine with a populated .build.
cat >"$TMP_DIR/ResourceBundle.swift" <<'SWIFT'
import Foundation
extension Bundle {
    static var module: Bundle { fatalError("Packaged certificate accessed the developer resource bundle") }
}
SWIFT
cat >"$TMP_DIR/main.swift" <<'SWIFT'
import AppKit
MainActor.assumeIsolated {
    _ = NSApplication.shared
    precondition(Bundle.main.bundleURL.pathExtension == "app")
    let expectedAssets = CommandLine.arguments[1] == "present"
    let view = LicenseCertificateView()
    let logo = view.subviews.compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "Stacio" }
    precondition(logo != nil)
    precondition((logo?.image != nil) == expectedAssets, "Incorrect packaged icon loading")
    if expectedAssets {
        precondition(NSFont(name: "Lack-Regular", size: 32) != nil, "Packaged brand font did not load")
    }
    print("PASS: packaged certificate, resources \(expectedAssets ? "present" : "missing"), no developer bundle access")
}
SWIFT

"$SWIFT_COMPILER" -sdk "$SDK_PATH" -D SWIFT_PACKAGE \
  "$ROOT_DIR/Stacio/Views/Dialogs/LicenseCertificateView.swift" \
  "$TMP_DIR/ResourceBundle.swift" "$TMP_DIR/main.swift" -o "$TMP_DIR/CertificateProbe"

for mode in present missing; do
  APP_DIR="$TMP_DIR/$mode.app"
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  cp "$TMP_DIR/CertificateProbe" "$APP_DIR/Contents/MacOS/CertificateProbe"
  cat >"$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CertificateProbe</string>
<key>CFBundleIdentifier</key><string>cn.stacio.certificate-resource-test.$mode</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  if [[ "$mode" == "present" ]]; then
    cp -R "$ROOT_DIR/Stacio/Resources/LicenseCertificate" "$APP_DIR/Contents/Resources/"
  fi
  "$APP_DIR/Contents/MacOS/CertificateProbe" "$mode"
done
