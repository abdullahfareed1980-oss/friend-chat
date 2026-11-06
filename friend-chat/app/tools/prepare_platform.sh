#!/usr/bin/env bash
#
# Materialise the Flutter platform folders (android/, windows/) that this repo
# deliberately does not track, then apply the Friend Chat overlay on top:
#
#   AndroidManifest.xml          permissions, foreground service, receivers
#   network_security_config.xml  LAN cleartext policy
#   build.gradle.kts             minSdk, desugaring, release signing
#
# Used by .github/workflows/build.yml and safe to run locally before
# `flutter run` / `flutter build`. Re-running it is idempotent: the generated
# files are overwritten, windows/installer/ is preserved.
#
# Signed release APK: export ANDROID_KEYSTORE_BASE64 plus ANDROID_STORE_PASSWORD,
# ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD. Without them the APK is unsigned,
# never debug-signed.
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
PLATFORMS="android,windows"

if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
    echo "error: '$FLUTTER_BIN' is not on PATH (set FLUTTER_BIN=/path/to/flutter)" >&2
    exit 1
fi

SCAFFOLD="$(mktemp -d)"
trap 'rm -rf "$SCAFFOLD"' EXIT

echo "==> Scaffolding $PLATFORMS with $("$FLUTTER_BIN" --version | head -n 1)"
"$FLUTTER_BIN" create \
    --org com.friendchat \
    --project-name friend_chat \
    --platforms "$PLATFORMS" \
    --no-pub \
    "$SCAFFOLD" >/dev/null

mkdir -p android windows
cp -R "$SCAFFOLD/android/." android/
cp -R "$SCAFFOLD/windows/." windows/

# Absolute SDK paths for the machine that generated it; every machine has its own.
rm -f android/local.properties

echo "==> Applying the Friend Chat overlay"
cp -R platform/android/. android/

# --- release signing --------------------------------------------------------
if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
    KEYSTORE="$APP_DIR/android/friend-chat-release.jks"
    printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d >"$KEYSTORE"
    chmod 600 "$KEYSTORE"
    cat >android/key.properties <<EOF
storePassword=${ANDROID_STORE_PASSWORD:-}
keyPassword=${ANDROID_KEY_PASSWORD:-}
keyAlias=${ANDROID_KEY_ALIAS:-friendchat}
storeFile=${KEYSTORE}
EOF
    chmod 600 android/key.properties
    echo "==> Release signing configured (keystore + key.properties are gitignored)"
else
    echo "==> ANDROID_KEYSTORE_BASE64 is not set: the release APK will be UNSIGNED"
fi

echo "==> Ready"
echo "    android/  ->  $( [ -f android/key.properties ] && echo 'signed with your keystore' || echo 'unsigned' )"
echo "    windows/  ->  installer script kept at windows/installer/friend-chat.iss"
