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
# Inside Homebrew's build sandbox the keychain is unreachable and this falls back to ad hoc; the
# app's updater re-signs the installed bundle afterwards. The keychain is named from the account's
# home in the user database because Homebrew also points HOME at a temporary folder.
REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')"
KEYCHAIN="${REAL_HOME:-$HOME}/Library/Keychains/login.keychain-db"
# Not `-v`: with HOME moved, security cannot reach the issuer chain to validate, so expired
# identities are skipped by their CSSMERR suffix instead.
IDENTITY="${CLAUDETERM_SIGN_IDENTITY:-$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
  | awk '/"Apple Development:/ && !/CSSMERR/ { print $2; exit }')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --keychain "$KEYCHAIN" --sign "$IDENTITY" "$ROOT/build/ClaudeTerm.app"
  echo "Signed with $IDENTITY"
else
  echo "No signing certificate found; ad-hoc signature (folder permissions reset on each update)"
fi
echo "Built $ROOT/build/ClaudeTerm.app"
