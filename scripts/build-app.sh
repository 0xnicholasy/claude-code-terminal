#!/bin/sh
# Release build of ClaudeTerm.app into build/ClaudeTerm.app. Used by the Homebrew formula.
# All caches stay inside the repo so the build works under Homebrew's sandbox.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/App"
# Homebrew already sandboxes the build, and macOS cannot nest sandbox-exec, so the
# formula sets CLAUDETERM_NO_SPM_SANDBOX=1 to stop SwiftPM from adding its own.
set --
if [ "${CLAUDETERM_NO_SPM_SANDBOX:-0}" = 1 ]; then
  set -- -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES \
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
fi
xcodegen generate --quiet
xcodebuild -scheme ClaudeTerm -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/build/DerivedData" \
  -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
  "$@" -quiet build
rm -rf "$ROOT/build/ClaudeTerm.app"
cp -R "$ROOT/build/DerivedData/Build/Products/Release/ClaudeTerm.app" "$ROOT/build/ClaudeTerm.app"
echo "Built $ROOT/build/ClaudeTerm.app"
