# Building the installers

Two artefacts are required by the brief: an **Android `.apk`** and a **Windows
`.exe`** installer. Both come from the same Flutter project in `app/`.

Neither can be produced inside this repository's container (no Android SDK, no
Windows toolchain), so this is the exact procedure to run on your machine — or
let CI do it (see [CI](#ci-one-tag--both-artefacts) below).

---

## 0. One-time scaffolding

The project ships Dart code and assets, not the generated platform folders, so
generate them once and keep them:

```bash
cd app && ./tools/prepare_platform.sh
```

That script (also used by CI) does the whole of section 0:

1. `flutter create --org com.friendchat --project-name friend_chat --platforms
   android,windows` into a temp dir, and copies the two platform folders in
   (`windows/` is merged, so `windows/installer/` survives).
2. Copies the overlay in [`app/platform/`](../app/platform) over the result:
   the manifest with its permissions and foreground service, the LAN cleartext
   policy, and `build.gradle.kts` with `minSdk 23`, desugaring and release
   signing driven by `android/key.properties`.
3. Writes the keystore and `key.properties` when `ANDROID_KEYSTORE_BASE64` is
   set; otherwise leaves the release build unsigned.

Re-running it is safe: it never touches `lib/`, `pubspec.yaml`, `assets/` or
`windows/installer/`. It is also why `android/` is gitignored — regenerate it
rather than committing it.

[PLATFORM_SETUP.md](PLATFORM_SETUP.md) remains the explanation of *why* each of
those pieces is there; the files themselves now live in `app/platform/`.

With the folders in place:

```bash
flutter pub get
flutter analyze          # expect: No issues found!
flutter run              # sanity check on a device / emulator
```

---

## 1. Android APK

### Debug build (fastest, for a friend's phone)

```bash
flutter build apk --debug
# build/app/outputs/flutter-apk/app-debug.apk
```

### Release build

```bash
flutter build apk --release --split-per-abi
```

Outputs:

```
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk     ← most phones
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk   ← old 32-bit
build/app/outputs/flutter-apk/app-x86_64-release.apk        ← emulators
```

A single universal APK is `flutter build apk --release` (bigger, works
everywhere).

### Signing it properly

Unsigned release APKs install, but Play Protect and some vendors complain and
you cannot update an app in place without a stable key.

```bash
keytool -genkey -v -keystore ~/friend-chat-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias friendchat
```

`android/key.properties` (never commit this):

```properties
storePassword=…
keyPassword=…
keyAlias=friendchat
storeFile=/home/you/friend-chat-upload.jks
```

In `android/app/build.gradle.kts`, before `android { … }`:

```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```

and inside `android { }`:

```kotlin
signingConfigs {
    create("release") {
        keyAlias = keystoreProperties["keyAlias"] as String
        keyPassword = keystoreProperties["keyPassword"] as String
        storeFile = file(keystoreProperties["storeFile"] as String)
        storePassword = keystoreProperties["storePassword"] as String
    }
}
buildTypes {
    getByName("release") {
        signingConfig = signingConfigs.getByName("release")
        isMinifyEnabled = true
        isShrinkResources = true
    }
}
```

Then `flutter build apk --release --split-per-abi` produces signed APKs.

### Installing on the other phone

Send the APK over any channel (Signal, USB, a local file server). The recipient
enables "install unknown apps" for their file manager. If Play Protect blocks
it, choose "Install anyway" — the build is signed with your own key, which is
the point.

### App icon

```bash
# any SVG/PNG converter, e.g. on a machine with librsvg
rsvg-convert -w 1024 -h 1024 assets/logo/friend_chat_logo.svg -o /tmp/icon.png
```

```yaml
# pubspec.yaml (dev_dependencies)
flutter_launcher_icons: ^0.14.1

flutter_launcher_icons:
  android: true
  windows:
    generate: true
    image_path: "assets/logo/icon.png"
    icon_size: 256
  image_path: "assets/logo/icon.png"
  adaptive_icon_background: "#0B0B14"
  adaptive_icon_foreground: "assets/logo/icon.png"
```

```bash
dart run flutter_launcher_icons
```

---

## 2. Windows `.exe`

Must be built **on Windows** (or a Windows CI runner) — Flutter does not
cross-compile desktop apps.

```powershell
flutter config --enable-windows-desktop
flutter build windows --release
```

Output:

```
build\windows\x64\runner\Release\
    friend_chat.exe
    flutter_windows.dll
    data\               ← assets, icudtl.dat, app.so
```

That folder is portable: zip it and it runs. For a real installer, use Inno Setup.

### Inno Setup → single `FriendChatSetup.exe`

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php).
2. The script is already in the repo:
   [`app/windows/installer/friend-chat.iss`](../app/windows/installer/friend-chat.iss).
3. Build:

```powershell
iscc windows\installer\friend-chat.iss
# dist\FriendChatSetup-1.0.0.exe
```

The script installs per-user (no UAC prompt), creates Start-menu and desktop
shortcuts, registers an uninstaller, and keeps user data out of `Program Files`.
It assumes the release output exists at
`build\windows\x64\runner\Release\`.

### Notes for the desktop build

* `flutter_secure_storage` on Windows uses DPAPI — the encrypted Hive key is tied
  to the Windows user account.
* There is no foreground service on desktop; the socket lives while the app runs.
* Add a firewall exception if you connect to a LAN server on a different subnet.

---

## CI: one tag → both artefacts

[`.github/workflows/build.yml`](../.github/workflows/build.yml) builds both
artefacts on GitHub's runners (which have the Android SDK and Visual Studio that
the app needs) and attaches them to a Release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

That run produces, on the Release page:

```
FriendChatSetup-1.0.0.exe                        ← per-user Windows installer
friend-chat-1.0.0-arm64-v8a.apk                  ← most phones
friend-chat-1.0.0-armeabi-v7a.apk                ← old 32-bit devices
friend-chat-1.0.0-x86_64.apk                     ← emulators
```

A manual run (Actions → Build installers → Run workflow) builds the same files
without publishing a Release, and accepts a version override.

The tag supplies the version: `v1.2.3` becomes `versionName 1.2.3` in the APK and
`FriendChatSetup-1.2.3.exe` from Inno Setup. The build number is the run number.

### Signing secrets

Without these the APK is built **unsigned** (it installs, but cannot be updated
in place and some vendors warn). Add them under Settings → Secrets and variables
→ Actions:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 ~/friend-chat-upload.jks` |
| `ANDROID_STORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `friendchat` |
| `ANDROID_KEY_PASSWORD` | key password |

The workflow never prints them, and both the keystore and `key.properties` land
only in the runner's `app/android/` folder, which `.gitignore` covers.

**Keep the keystore file backed up.** Losing it means the next APK is a different
app to Android and users must uninstall (losing the encrypted local cache, not
the server's messages) before installing the update.

---

## 3. Versioning

`pubspec.yaml` `version: 1.0.0+1` → `1.0.0` is `versionName` /
`CFBundleShortVersionString`, `1` is `versionCode`. The Inno script reads the
version from a `#define` at the top; bump both together.

---

## 4. Checklist before handing the APK over

- [ ] `flutter analyze` clean
- [ ] Signed with your keystore (not debug)
- [ ] `OTP_DEBUG=false` on the server it will talk to
- [ ] Both phone numbers enrolled with `npm run seed -- --rotate`
- [ ] Server reachable from the phone's Wi-Fi **and** mobile data
- [ ] Safety numbers compared in person after both devices sign in
