#!/bin/zsh
# Compiles the Foundation-only core (everything under Dotto/Core, every feature subfolder) together with
# DottoCoreTests into a scratch executable and runs it. No xcodebuild: that would re-sign the app and
# invalidate its TCC grants. The core file list is a glob, so new Core files are picked up automatically.
set -euo pipefail

repositoryRootDirectory="${0:A:h:h}"
xcodeDeveloperDirectory="/Applications/Xcode.app/Contents/Developer"
swiftCompilerPath="$xcodeDeveloperDirectory/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
macOSSDKPath="$(ls -d $xcodeDeveloperDirectory/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.*.sdk | sort -V | tail -1)"
# A fresh directory per run so concurrent runs (several agents at once) never overwrite each other's build inputs.
scratchDirectory="$(mktemp -d "${TMPDIR:-/tmp}/dotto-core-tests.XXXXXX")"
trap 'rm -rf "$scratchDirectory"' EXIT

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

coreSourceFiles=("${(@f)$(find "$repositoryRootDirectory/Dotto/Core" -name '*.swift' | sort)}")
testSourceFiles=("${(@f)$(find "$repositoryRootDirectory/DottoCoreTests" -name '*.swift' | sort)}")

# Core must stay testable without AppKit, so any import besides Foundation/CoreGraphics fails the run.
forbiddenImportLines="$(grep -nE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' "${coreSourceFiles[@]}" \
  | grep -vE 'import[[:space:]]+(Foundation|CoreGraphics)[[:space:]]*(//.*)?$' || true)"
if [[ -n "$forbiddenImportLines" ]]; then
  echo "Core files may only import Foundation or CoreGraphics:" >&2
  echo "$forbiddenImportLines" >&2
  exit 1
fi

# Invariant 8: the executor never writes routines to disk, so nothing under Core/Execution may even name the store.
executionFilesNamingRoutineLibraryStore="$(grep -lw 'RoutineLibraryStore' "$repositoryRootDirectory"/Dotto/Core/Execution/**/*.swift || true)"
if [[ -n "$executionFilesNamingRoutineLibraryStore" ]]; then
  echo "Dotto/Core/Execution must not reference RoutineLibraryStore (routines are saved only after the user reviews them):" >&2
  echo "$executionFilesNamingRoutineLibraryStore" >&2
  exit 1
fi

testSuiteNames=("${(@f)$(grep -hoE 'let [A-Za-z0-9_]+TestSuite = CoreTestSuite\(' "${testSourceFiles[@]}" \
  | sed -E 's/^let ([A-Za-z0-9_]+) = .*/\1/' | sort)}")
generatedMainPath="$scratchDirectory/GeneratedCoreTestMain.swift"
{
  echo "import Foundation"
  echo "@main struct GeneratedCoreTestMain {"
  echo "    static func main() async {"
  echo "        let failureCount = await runCoreTestSuites([${(j:, :)testSuiteNames}])"
  echo "        exit(failureCount == 0 ? 0 : 1)"
  echo "    }"
  echo "}"
} > "$generatedMainPath"

"$swiftCompilerPath" -parse-as-library \
  -sdk "$macOSSDKPath" \
  -target arm64-apple-macos14.2 "${swiftLanguageFlags[@]}" \
  -o "$scratchDirectory/DottoCoreTests" \
  "${coreSourceFiles[@]}" "${testSourceFiles[@]}" "$generatedMainPath"

"$scratchDirectory/DottoCoreTests"
