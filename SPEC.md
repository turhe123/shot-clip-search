# ShotClipSearch — specification

**Tagline:** A clipboard history for images and screenshots where you can search the words inside every picture you copied.

**Category:** Clipboard

**Inspired by (paid):** Cliply ($9 one-time)

**Frameworks:** SwiftUI, AppKit, Vision, UniformTypeIdentifiers, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does and the demand. Cliply is a native Apple Silicon clipboard manager sold through Gumroad starting at 9 dollars as a one-time purchase with a 14 day refund. It manages text, images and screenshots in one history. Image clipboard managers appear repeatedly in 2026 clipboard roundups and indie listings, which shows people want more than text history. Our version, ShotClipSearch, is image first: it stores every copied picture and makes the text inside it searchable using on-device recognition.

Feature set. The app watches the pasteboard for images (PNG, TIFF, JPEG) and also for screenshots copied with the system screenshot shortcut. Each image is saved as a compressed file with a small thumbnail. Vision text recognition runs in the background and stores the recognized text beside the entry. A search field filters the gallery by recognized words. Selecting a card and pressing Return puts the image back on the pasteboard. Space opens a large preview. Delete removes an entry. A Pin action keeps an image from expiring. Text copies are ignored, so this complements a normal text clipboard tool.

UI spec. A window app with a MenuBarExtra for quick access. The main window shows an adaptive grid of thumbnail cards with the first line of recognized text under each card and a timestamp. The toolbar holds the search field, a size slider for the grid, and a Clear Unpinned button with a confirmation dialog. Settings fields are retention (7, 30, 90 days or forever), maximum stored images (50 to 1000), recognition language choice (automatic or a picked language), launch at login, and the global hotkey that opens the gallery (default Command Shift V). Empty states read No images copied yet and No pictures contain that text.

Technical approach. Poll NSPasteboard changeCount on a timer and read NSImage data when present. Write the original data to a folder in Application Support using a UUID file name and generate a 256 point thumbnail with CoreGraphics image scaling. Keep an index file in JSON with id, date, pinned flag, pixel size, source application name from the frontmost app at copy time, and recognized text. Run VNRecognizeTextRequest at the accurate level on a background task queue, one image at a time, then update the index on the main actor. Use a Carbon hotkey for the global shortcut. No Screen Recording or Accessibility permission is needed because only the pasteboard is read. Launch at login uses SMAppService.

Edge cases. Very large images over 40 megapixels are stored but skipped for recognition, with a small badge saying Not indexed. If recognition returns nothing, show No text found and keep the card searchable by date. Avoid duplicate entries by hashing the image bytes. Enforce retention at launch and once a day, deleting files before index entries so the folder does not grow. If disk writes fail, show a banner and stop capturing instead of crashing. Respect the transient pasteboard type used by apps for sensitive images and skip those. Handle pasteboards that carry both image and file URL by preferring the image data. Cap the recognition queue at 20 pending items and drop the oldest if the user copies rapidly.
