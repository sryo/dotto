#!/bin/zsh
# Typechecks every app source file with Xcode's toolchain without producing a signed
# app bundle. Running xcodebuild would re-sign the app and invalidate its TCC grants
# (Screen Recording, Accessibility), so this is the safe compile gate for agents and CI.
set -euo pipefail

repositoryRootDirectory="${0:A:h:h}"
xcodeDeveloperDirectory="/Applications/Xcode.app/Contents/Developer"
swiftCompilerPath="$xcodeDeveloperDirectory/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
macOSSDKPath="$(ls -d $xcodeDeveloperDirectory/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.*.sdk | sort -V | tail -1)"

# Mirrors the Dotto target's Swift build settings in Dotto.xcodeproj (SWIFT_VERSION 5, approachable
# concurrency, member import visibility) so this gate fails exactly where Xcode's build would.
swiftLanguageFlags=(
  -swift-version 5
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature InferSendableFromCaptures
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -enable-upcoming-feature DisableOutwardActorInference
  -enable-upcoming-feature MemberImportVisibility
)

appSourceFiles=("${(@f)$(find "$repositoryRootDirectory/Dotto" -name '*.swift' | sort)}")

"$swiftCompilerPath" -typecheck \
  -sdk "$macOSSDKPath" \
  -target arm64-apple-macos14.2 "${swiftLanguageFlags[@]}" \
  "${appSourceFiles[@]}"

echo "typecheck OK (${#appSourceFiles[@]} files)"
