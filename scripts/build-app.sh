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

# Re-sign with a certificate when one is available. An ad-hoc signature changes with every build,
# so macOS forgets ClaudeTerm's folder permissions (Desktop, Documents) after each update; a
# certificate signature keeps the same identity across builds. CLAUDETERM_SIGN_IDENTITY picks one
# (a SHA-1 hash or name); otherwise the first valid "Apple Development" identity is used.
IDENTITY="${CLAUDETERM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/"Apple Development:/ { print $2; exit }')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$ROOT/build/ClaudeTerm.app"
  echo "Signed with $IDENTITY"
else
  echo "No signing certificate found; ad-hoc signature (folder permissions reset on each update)"
fi
echo "Built $ROOT/build/ClaudeTerm.app"
