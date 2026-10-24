# Documentation screenshots

Run on macOS with Command Line Tools installed:

```sh
bash docs/screenshots/render.sh
```

The script compiles the current application views with a separate entry point and runs compilation and rendering at a lower scheduling priority. It renders English and Chinese JPEGs into `docs/images/` using hidden hosting windows, without calling `orderFront`, `makeKeyAndOrderFront`, or `activate`. It does not launch or quit the installed application, register global shortcuts, or take a screen capture.

All history, preferences, pasteboard data, and OCR caches are isolated temporary fixtures. The image contains synthetic Chinese and English text; Apple's actual local OCR generates its searchable text and highlight coordinates before rendering. The renderer checks that the query produces highlight boxes rather than drawing a made-up overlay. History and settings fixtures are removed when rendering finishes; the compiled helper remains in its printed temporary build directory.

Scenes cover the current light and dark shelf, full-pinyin and initials searches, image text search, enlarged preview highlights, compact source filters, collection selection, modifier hints, sequential queue, general settings, and keyboard settings. The keyboard page receives its own isolated settings state; no clicks or accessibility control are needed. These are offscreen renders of the real views, not a recording or an end-to-end interaction test.
