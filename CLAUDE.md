# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Flutter plugin that provides native PDF viewing capabilities for iOS and Android platforms. Both platforms render PDF pages to Flutter textures using native PDF APIs — no platform views are used.

- **iOS**: PDFKit (iOS 11.0+), rendered to `CVPixelBuffer` via `CGContext`, registered as a `FlutterTexture`
- **Android**: `android.graphics.pdf.PdfRenderer` (API 21+), rendered to `Bitmap` via a `SurfaceTexture`, registered as a `FlutterTexture`

Because the implementation is texture-based (not platform-view based), it works correctly on secondary Flutter engines (e.g. an external display running inside a `Presentation` with application context).

## Key Commands

### Development & Testing
```bash
# Install dependencies
flutter pub get

# Run tests
flutter test

# Run tests for a specific file
flutter test test/flutter_pdfview_test.dart

# Analyze code
flutter analyze

# Format code
dart format .
```

### Example App
```bash
# Run the example app
cd example
flutter pub get
flutter run

# Build example for specific platform
flutter build ios
flutter build apk
```

### Publishing
```bash
# Dry run before publishing
flutter pub publish --dry-run

# Publish to pub.dev
flutter pub publish
```

## Architecture

### Plugin Structure

1. **Core Dart Interface** (`lib/flutter_pdfview.dart`):
   - `PDFView` widget — creates the texture-based view on iOS and Android
   - `PDFViewController` — controller for page navigation (`getPageCount`, `getCurrentPage`, `setPage`)
   - Multi-page PDFs use a Flutter `PageView` with one texture per page (`_NativePageTexture`)
   - Single-page or non-swipeable PDFs use a single shared texture

2. **Android Implementation** (`android/src/main/java/io/endigo/plugins/pdfviewflutter/`):
   - `PDFViewFlutterPlugin.java` — plugin registration
   - `AndroidPDFTextureFactory.java` — method channel factory (`plugins.endigo.io/pdfview_factory`); handles `create` / `dispose`
   - `AndroidPDFTextureRenderer.java` — renders pages via `PdfRenderer` onto a `SurfaceTexture`; one instance per page in PageView mode

3. **iOS Implementation** (`ios/flutter_pdfview/Sources/flutter_pdfview/`):
   - `PDFViewFlutterPlugin.m` — plugin registration
   - `FLTPDFTextureRenderer.swift` — renders pages via PDFKit into a `CVPixelBuffer`; implements `FlutterTexture`

### Communication Flow

1. Flutter creates `PDFView` widget and calls `plugins.endigo.io/pdfview_factory → create` for each page (or one probe call + per-page calls in PageView mode)
2. Native side creates a renderer, renders the default page, returns `{textureId, channelName, renderWidth, renderHeight}`
3. Flutter displays `Texture(textureId: id)` sized to `renderWidth/pixelRatio × renderHeight/pixelRatio`
4. Events flow back via the per-renderer method channel: `onRender`, `onPageChanged`, `onError`
5. `PDFViewController` calls `setPage`, `getPageCount`, `getCurrentPage` on the per-renderer channel

### Key Features

- **File Loading**: From file path or binary data (`Uint8List`)
- **Navigation**: Page navigation, swipe gestures, horizontal/vertical scrolling via Flutter `PageView`
- **Rendering**: Night mode, auto-spacing, page snap, fit policies
- **Security**: Password-protected PDF support (iOS)
- **Callbacks**: Page change, render complete, error handling, link handling
- **Mixed page sizes**: Pages with different dimensions are each rendered at their own aspect ratio
- **Secondary engine support**: Works on secondary Flutter engines (external displays, `Presentation`)

## Platform-Specific Considerations

### iOS
- Minimum iOS version: 11.0 (PDFKit requirement)
- Uses Swift Package Manager for dependency management
- Renders using `cropBox` bounds for correct visible-area sizing

### Android
- Minimum SDK: 21
- Compile SDK: 35
- Uses `android.graphics.pdf.PdfRenderer` — no third-party PDF library required
- Rendering runs on a dedicated single-thread `ExecutorService`; `textureEntry.release()` is always posted back to the main thread
- Pages use a `Matrix` transform to scale-to-fit with correct centering (avoids stretching for mixed-dimension PDFs)

## Testing Approach

Tests are in `test/flutter_pdfview_test.dart` and include:
- Widget creation and configuration tests
- Settings validation tests
- Error handling tests
- Mock method channel for platform communication

The example app (`example/lib/main.dart`) provides comprehensive testing scenarios:
- Loading from assets
- Loading from URL
- Corrupted PDF handling
- Landscape PDF rendering
- PDF with links

## Common Development Tasks

### Adding a New Feature
1. Define the feature in the Dart interface (`lib/flutter_pdfview.dart`)
2. Implement in Android (`android/src/main/java/`)
3. Implement in iOS (`ios/flutter_pdfview/Sources/`)
4. Add tests in `test/flutter_pdfview_test.dart`
5. Update example app to demonstrate the feature
6. Update `README.md` with feature documentation

### Debugging Platform Code
- **Android**: Open `android/` in Android Studio, attach debugger
- **iOS**: Open `example/ios/Runner.xcworkspace` in Xcode, use breakpoints

### Version Updates
1. Update version in `pubspec.yaml`
2. Update `CHANGELOG.md` with changes
3. Run tests and example app
4. Publish using `flutter pub publish`
