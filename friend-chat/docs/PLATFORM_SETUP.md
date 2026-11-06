# Platform setup

Everything the generated Flutter folders need before the app will behave. Run
`flutter create` first (see [BUILD.md](BUILD.md)).

---

## Android

### 1. `android/app/src/main/AndroidManifest.xml`

Replace the manifest with this. The parts that matter are commented.

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- network -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <!-- notifications without FCM -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />

    <!-- foreground service (Android 14 requires both the permission and the type) -->
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />

    <!-- picking an attachment -->
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />

    <application
        android:label="Friend Chat"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:networkSecurityConfig="@xml/network_security_config">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />

        <!-- flutter_foreground_task: keeps the socket alive -->
        <service
            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
            android:foregroundServiceType="dataSync"
            android:exported="false" />

        <!-- local notifications, scheduled delivery -->
        <receiver
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"
            android:exported="false" />
        <receiver
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"
            android:exported="false">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
            </intent-filter>
        </receiver>
    </application>

    <!-- Required so image_picker / file_picker can resolve handlers on Android 11+ -->
    <queries>
        <intent>
            <action android:name="android.intent.action.GET_CONTENT" />
            <data android:mimeType="*/*" />
        </intent>
        <intent>
            <action android:name="android.intent.action.PICK" />
            <data android:mimeType="image/*" />
        </intent>
    </queries>
</manifest>
```

### 2. `android/app/src/main/res/xml/network_security_config.xml`

Friend Chat talks to `http://192.168.x.x:8787` on your LAN, which Android 9+
blocks by default. Allow cleartext **only** on private ranges; keep the public
internet HTTPS-only.

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">localhost</domain>
        <domain includeSubdomains="true">10.0.2.2</domain>
        <domain includeSubdomains="true">192.168.0.0</domain>
        <domain includeSubdomains="true">192.168.1.0</domain>
    </domain-config>
</network-security-config>
```

For a LAN IP outside those prefixes, add a `<domain>` entry (or use a
`network-security-config` with an explicit IP list). Tailscale `100.x`
addresses: add `<domain includeSubdomains="true">100.64.0.0</domain>` — Android
matches these as domain strings, so a `/10` CIDR is not supported; the practical
option is to use TLS on the tailnet or add the specific IP.

### 3. `android/app/build.gradle.kts`

```kotlin
android {
    defaultConfig {
        applicationId = "com.friendchat.friend_chat"
        minSdk = 23
        targetSdk = 35
        multiDexEnabled = true
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.2")
}
```

Desugaring is required by `flutter_local_notifications`. `minSdk 23` is the floor
for the foreground service and the crypto packages.

### 4. Battery optimisation

Android may still kill the service on aggressive OEM builds (Xiaomi, Huawei,
Samsung). Ask the user once, from Settings:

```dart
FlutterForegroundTask.requestIgnoreBatteryOptimization();
```

The foreground service notification must stay visible — that is the OS rule, and
hiding it would be dishonest.

---

## Windows

Generated by `flutter create --platforms windows`.

* No manifest changes are required for networking.
* `flutter_secure_storage` uses DPAPI: the local cache is tied to the Windows
  user profile.
* The app has no background service; the socket is alive while the window is.
* Ship the whole `Release` folder (exe + dll + `data/`), or use the Inno Setup
  script in `windows/installer/friend-chat.iss`.

```
build\windows\x64\runner\Release\
```

---

## iOS (source-compatible, with a caveat)

The Dart code runs on iOS, but be honest about the background story:

* `flutter_foreground_task` on iOS shows a persistent notification only while the
  app is foregrounded; there is **no** supported way to keep a socket open
  indefinitely in the background.
* Without APNs, notifications arrive when the app is opened (or during the short
  window iOS grants after backgrounding).

If iOS matters, the realistic options are (a) accept "sync on open", (b) run a
self-hosted UnifiedPush distributor, or (c) accept APNs. The code does not
pretend otherwise — `docs/SECURITY.md` and the Settings screen both say it.

---

## Desktop / web notes

* `flutter run -d windows` for the desktop app; `-d chrome` works for UI work but
  `flutter_secure_storage` and Hive need a platform build, so desktop/mobile are
  the real targets.
* On Windows, if the server is on another subnet, allow `friend_chat.exe` through
  Windows Defender Firewall (private networks).

---

## Permissions the app will ask for

| Permission | When | Why |
| --- | --- | --- |
| Notifications | first launch | message alerts (local, not push) |
| Foreground service | after sign-in, Android | keep the socket alive |
| Ignore battery optimisation | optional, Settings | survive OEM task killers |
| Photos/files | on attach | choosing what to send |

Nothing else. No contacts, no location, no camera-only access, no analytics.
