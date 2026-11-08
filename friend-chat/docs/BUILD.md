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

Before either build starts, a `checks` job lints the workflow files, then runs
`flutter analyze`, `flutter test` and a coverage floor check on the same pinned
Flutter. `flutter analyze` exits non-zero on errors *and* warnings, and both build
jobs declare `needs: checks`, so a tag whose code does not analyse, whose tests
fail, or whose instrumented coverage is under 100% publishes nothing — no
half-built release, no installer that cannot decrypt. The floor is
`COVERAGE_FLOOR` at the top of the workflow; see [Coverage](#coverage) for what it
does and does not measure.

The first of those steps, **Lint workflow files**, downloads a pinned actionlint
(`1.7.12`, never `main`) and points it at `.github/workflows/*.yml`. actionlint
parses the YAML against GitHub's schema and hands every `run:` block to
shellcheck, so a mistyped runner label, an unknown expression context or a
quoting bug in a script fails the job in seconds — before Flutter is even set up.
It insists on shellcheck being present, since without it actionlint silently skips
the scripts and the check would pass while linting almost nothing. To run it
locally: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12`.

That lint only runs when this workflow runs, and this workflow fires on `v*` tags
and manual dispatch — so it cannot catch a bad workflow edit *before* you tag;
run the container above when you touch `.github/`.

The suite in [`app/test/`](../app/test) is 194 tests over the pieces that are
expensive to debug on a phone:

* `models_test.dart` (70) — every model's JSON round trip (user, attachment,
  catalog item and snapshot, message, envelope, quick reply, label, auto-reply
  settings, endpoint) plus the wire parsing the app relies on when the server
  sends something unexpected: unknown `kind`/`status` names, missing optional
  fields, non-map sections, an unparseable `createdAt` (falls back to now so the
  bubble still sorts), invalid hex colours. Also the display helpers: initials,
  relative time, clock, byte sizes, currency labels, away-window arithmetic.
  This file caught two real bugs: `AutoReplySettings.fromJson({})` threw on the
  first-launch path (a const empty map is not a `Map<String, dynamic>`), and
  `kindToWire` had no test proving it matches what `fromWire` parses.

* `crypto_service_test.dart` (14) — envelope round-trip, tamper detection (a
  flipped byte must not decrypt), sender/conversation binding, identity
  persistence and corruption handling, attachment sealing, safety-number
  symmetry.
* `connection_manager_test.dart` (20) — LAN beats a faster public endpoint,
  lowest RTT wins within a kind, probes run in parallel, offline paths, cache
  reuse, re-race after `reportFailure`, `advancePast`, `reportOnline` merging
  peer state. Plus the parts that need the OS: a fake `NetworkWatcher` shows
  that `start()` is idempotent, that a transport change is published to the UI
  and re-races, that `isOnMobileData` is true only when cellular is the sole
  transport, and that the watchdog (interval injectable, 20 ms in tests) looks
  for a server when there is none, refreshes the badge when there is, and demotes
  an endpoint whose health check fails. One test drives the real
  `PluginNetworkWatcher` through mocked plugin channels, so the wiring to
  `connectivity_plus` is exercised rather than assumed.
* `rest_client_test.dart` (24) — the HTTP client against a scripted
  `http.Client`, so the promises that are invisible in a green E2E run are
  asserted directly: `no-store` on every request, `authorization` only when
  signed in, JSON content type on POST/PUT but not GET, octet-stream plus the
  `x-fc-media` digest header on media upload, raw bytes back on download. Error
  bodies map to `ApiException` with status/code/hint, a bodyless 500 becomes
  `http_500`, 401/403 are recognisable as auth failures, and a failed media
  download reports `media_fetch_failed` instead of returning empty bytes. A
  server that never answers becomes `TimeoutException` rather than a spinner
  that lives forever — that test needs a 20 ms injected timeout, which is why
  `ApiClient` takes an optional `client` and `timeout` (the constructor still
  defaults to a real socket and 15 s). Also the request shapes nothing else
  exercises: password login with and without the device block, `me()` injecting
  the stored token, sync's `latestSeq` fallback, a null peer directory entry.
* `auto_responder_test.dart` (14) — the away/greeting rules on a fixed clock:
  the away window (inside, outside, overnight), a blank text sending nothing,
  the per-kind cooldown holding a repeat back and releasing it once it lapses,
  an unreadable stamp treated as no cooldown, greeting only on a restarted
  conversation and only on its own cooldown, away winning when both are due.
  Settings load/save round trip, and `statusLine` for all four combinations.
  This needed one seam: `AutoResponder` takes a `MetaStore` (read/write meta)
  instead of a concrete `LocalStore`, so the test uses a map and no Hive box,
  keystore key or plugin channel — the same seam idea as `NetworkWatcher`. It
  lives in its own file so a test can import the interface without loading the
  Hive-backed store and its file IO.
* `local_store_test.dart` (15) — the encrypted store itself, opened into a
  temporary directory through `open(..., path:)`. The Aes boxes are real, so
  these prove the round trip the app performs on every launch: put/get by uuid
  and client id, per-conversation filtering, seq ordering with a `createdAt`
  fallback for outbox rows that have no cursor yet, batch writes, delete (which
  also drops the seq entry), cursor precedence (stored value, else highest seq,
  with a non-int falling through), typed meta reads including type mismatches,
  map/list readers that filter junk shapes, `removeMeta`, and the JSON export
  with and without a stored conversation. The last test calls `open()` with no
  path and answers the `path_provider` channel by hand, so the real
  `Hive.initFlutter()` branch runs instead of being skipped.
* `e2e/live_server_test.dart` (15) — no fakes: it spawns `server/src/index.js` on
  port 0 with a throwaway data directory, seeds both accounts through
  `src/seed.js`, then drives the real `ApiClient` the app uses — health, request
  OTP, verify, `/api/me`, peer directory and identity keys, sync, business docs
  with revision conflicts, the peer catalog, media upload/download with checksum
  rejection, and the 400/401/404/409 paths. Message *delivery* is not here: sends
  go over Socket.io and are covered by `cd server && npm test`.
* `tools/coverage_html_test.dart` (22) — the coverage report generator itself:
  lcov parsing (repeated `DA:` records, junk lines, CRLF, no records), source
  path handling (relative, `./`, absolute, trailing slash, Windows separators,
  paths outside the root), every failure exit, and the HTML it writes (hit/miss/
  neutral rows, escaping, link depth from nested pages, rounding, empty files).
  It calls `buildReport()` in-process instead of spawning `dart`, which is why
  the tool separates that from `main()`.

The E2E file needs `node` >= 22.5 and `server/node_modules`. Run `npm ci` in
`server/` once; without it the file skips with a message so the unit suite still
works. CI installs them and sets `FC_E2E_REQUIRED=1`, which turns that skip into
a failure so the gate cannot pass by skipping. If you write another live test,
note it must clear `HttpOverrides.global`: `flutter_test` otherwise answers every
HTTP request with 400 to keep widget tests offline.

The tag supplies the version: `v1.2.3` becomes `versionName 1.2.3` in the APK and
`FriendChatSetup-1.2.3.exe` from Inno Setup. The build number is the run number.

### Coverage

`checks` runs `flutter test --coverage` and publishes the result three ways:

* **Run summary** — the percentage and per-file table sit at the bottom of the
  workflow run page, so seeing the number needs no download at all.
* **`coverage-html` artifact** — a browsable per-line report: `index.html` lists
  every file worst-first, and each file page shows the source with hit counts,
  covered lines in mint and misses in rose. Download it from the run's
  Artifacts section and open `index.html`; it is fully self-contained.
* **Release** — a tagged build appends the table to the release notes (between
  `<!-- coverage:start -->` / `<!-- coverage:end -->` sentinels, so re-running a
  tag replaces those numbers instead of stacking a second copy) and attaches the
  packaged report as `friend-chat-coverage-<version>.zip`. The raw
  `coverage/lcov.info` and the unpacked HTML stay on the workflow run.
* **GitHub Pages** — on a tagged build, `Publish coverage to Pages` deploys the
  same report to `https://<owner>.github.io/<repo>/`, so reviewers get a link
  rather than a download. The release notes carry that URL.
* **A floor that fails the build** — the last step of `checks` compares the total
  against `COVERAGE_FLOOR` (`100.0` in the workflow `env`) and exits non-zero under
  it, with `::error::` naming the number. Because both build jobs need `checks`,
  a tag that trips it publishes no APK and no installer. It reads the percentage
  the summary step wrote to `coverage/pct.txt` rather than recomputing it, so the
  number that fails a build is exactly the number in the table above it.

  The gate is the *last* step on purpose: the summary, the lcov file and both
  HTML artifacts are already uploaded, so a red run still tells you which lines
  went missing instead of failing before there is anything to look at. The floor
  is a single total, not per-file, because a per-file rule would fail on files the
  suite is not meant to load. It sits at the top of the range, so the only way a
  red run clears is to cover the missing lines or delete the code: lowering it to
  turn a build green is the one edit that makes the number worthless.

Pages needs one switch, once: **Settings → Pages → Build and deployment →
Source = GitHub Actions**. Until that is set the Pages job fails with GitHub's
own "Pages is not enabled" message — and the release still publishes, because
that job is deliberately not a dependency of `release`; the installers are the
product and a missing report must not block them.

> **Privacy note.** A Pages site built from a *private* repository is still
> public. The report contains source lines from `lib/`. If you would rather not
> publish those, leave Pages off — the artifact, the release zip and the summary
> table all keep working unchanged.

The HTML is generated by [`app/tools/coverage_html.dart`](../app/tools/coverage_html.dart),
a dependency-free lcov reader. `genhtml` would mean installing lcov on the
runner and on every dev machine, for a report whose job is only to answer
"which lines did the tests touch".

One caveat before quoting the number: `flutter test --coverage` only records
files a test actually loads, so the total covers the small number of `lib/`
files the suite reaches (currently 6 of 31: models, REST client, crypto service,
connection manager, auto-responder, local store) — and both the summary and the
HTML say so, rather than showing screens as 0%. All six are at 100% —
`models.dart` (323/323), `connection_manager.dart` (103/103), `rest_client.dart`
(99/99), `crypto_service.dart` (95/95), `auto_responder.dart` (30/30) and
`local_store.dart` (73/73) — so the report as a whole reads 100% (723/723) and
the workflow floor is 100 to match. Two unused helpers in `crypto_service.dart`
(an `identityPublicKey` getter and `hasNetworkInterface`) were deleted to get
there; covering them with tests would have been worse. The number still only
means anything because the rest of `lib/` — screens and platform services — is
not instrumented at all. `tools/` is outside `lib/` for
the same reason it is outside the app bundle, so the generator's own 22 tests
are not in the report even though they run in the same job.

Locally:

```bash
cd app
flutter test --coverage                 # writes coverage/lcov.info (gitignored)
dart run tools/coverage_html.dart       # writes coverage/html/index.html
open coverage/html/index.html           # xdg-open on Linux

flutter test test/tools/coverage_html_test.dart   # the generator's own tests
```

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
