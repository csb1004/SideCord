# SideCord

SideCord is a Flutter app that provides a Discord-aware Android overlay and a dccon browser/import workflow.

## Features

- Android overlay that appears while Discord is the foreground app.
- Image and text folder management for overlay content.
- Dccon search/detail browsing from DCInside Mall.
- Single icon or whole-package dccon import into app image folders.

## Development

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

For Android development, keep the Android SDK path configured in Android Studio and make sure `ANDROID_HOME` points to that SDK.
