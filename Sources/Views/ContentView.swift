import SwiftUI

/// Main gallery window: searchable adaptive grid of image cards with keyboard actions.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: PasteboardWatcher
    @AppStorage("gridSize") private var gridSize = 180.0
    @State private var query = ""
    @State private var selection: UUID?
    @State private var previewEntry: ClipEntry?
    @State private var confirmClear = false
    @State private var copiedFlash = false

    private var filtered: [ClipEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.text.localizedCaseInsensitiveContains(q)
                || (entry.sourceApp?.localizedCaseInsensitiveContains(q) ?? false)
                || entry.date.formatted(date: .complete, time: .shortened).localizedCaseInsensitiveContains(q)
        }
    }

    private var selectedEntry: ClipEntry? {
        filtered.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .searchable(text: $query, placement: .toolbar, prompt: "Search text in images")
        .toolbar {
            ToolbarItem {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3").imageScale(.small)
                    Slider(value: $gridSize, in: 120...320).frame(width: 110)
                    Image(systemName: "square.grid.2x2").imageScale(.large)
                }
                .help("Thumbnail size")
            }
            ToolbarItem {
                Button("Clear Unpinned", systemImage: "trash") { confirmClear = true }
                    .disabled(!store.entries.contains { !$0.pinned })
            }
        }
        .confirmationDialog("Delete all unpinned images?", isPresented: $confirmClear) {
            Button("Clear Unpinned", role: .destructive) { store.clearUnpinned(); selection = nil }
        } message: {
            Text("Pinned images are kept. This cannot be undone.")
        }
        .sheet(item: $previewEntry) { entry in
            PreviewView(entry: entry, onCopy: { copy(entry) })
        }
        .overlay(alignment: .bottom) {
            if copiedFlash {
                Text("Copied to clipboard")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var banner: some View {
        if let error = store.diskError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("\(error) Capturing is paused.").lineLimit(2)
                Spacer()
                Button("Resume") { state.resumeCapturing() }
            }
            .padding(10)
            .background(Color.red.opacity(0.15))
        } else if !watcher.isCapturing {
            HStack {
                Image(systemName: "pause.circle")
                Text("Capturing is paused.")
                Spacer()
                Button("Resume") { state.resumeCapturing() }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.12))
        }
    }

    @ViewBuilder private var content: some View {
        if store.entries.isEmpty {
            ContentUnavailableView("No images copied yet", systemImage: "photo.on.rectangle",
                                   description: Text("Copy an image or take a screenshot to the clipboard (⌃⇧⌘4) and it will appear here."))
        } else if filtered.isEmpty {
            ContentUnavailableView("No pictures contain that text", systemImage: "text.magnifyingglass",
                                   description: Text("Try different words, an app name or a date."))
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridSize), spacing: 14)], spacing: 14) {
                ForEach(filtered) { entry in
                    ClipCard(entry: entry, isSelected: entry.id == selection)
                        .onTapGesture(count: 2) { copy(entry) }
                        .onTapGesture { selection = entry.id }
                        .contextMenu { menu(for: entry) }
                }
            }
            .padding(14)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { act { copy($0) } }
        .onKeyPress(.space) { act { previewEntry = $0 } }
        .onKeyPress(.delete) { act { delete($0) } }
        .onKeyPress(.deleteForward) { act { delete($0) } }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }

    @ViewBuilder private func menu(for entry: ClipEntry) -> some View {
        Button("Copy") { copy(entry) }
        Button("Preview") { previewEntry = entry }
        Button(entry.pinned ? "Unpin" : "Pin") { store.togglePin(entry) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.imageURL(for: entry)]) }
        Divider()
        Button("Delete", role: .destructive) { delete(entry) }
    }

    private func act(_ action: (ClipEntry) -> Void) -> KeyPress.Result {
        guard let entry = selectedEntry else { return .ignored }
        action(entry)
        return .handled
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let items = filtered
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : items.count)
        selection = items[min(max(current + delta, 0), items.count - 1)].id
        return .handled
    }

    private func copy(_ entry: ClipEntry) {
        state.copyToPasteboard(entry)
        withAnimation { copiedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copiedFlash = false } }
    }

    private func delete(_ entry: ClipEntry) {
        let items = filtered
        if let idx = items.firstIndex(of: entry), items.count > 1 {
            selection = items[idx == items.count - 1 ? idx - 1 : idx + 1].id
        } else {
            selection = nil
        }
        store.delete([entry.id])
    }
}

/// A single thumbnail card with caption, timestamp, pin and indexing badges.
struct ClipCard: View {
    @EnvironmentObject private var store: ClipStore
    let entry: ClipEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = store.thumbnail(for: entry) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(4 / 3, contentMode: .fit)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 4) {
                    if entry.isNotIndexed { badge("Not indexed") }
                    if entry.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                }
                .padding(6)
            }
            Text(caption)
                .font(.callout)
                .foregroundStyle(entry.firstLine == nil ? .secondary : .primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
    }

    private var caption: String {
        switch entry.ocr {
        case .pending: return "Recognizing text…"
        case .tooLarge, .dropped: return "Text not recognized"
        case .done: return entry.firstLine ?? "No text found"
        }
    }

    private var subtitle: String {
        let time = entry.date.formatted(date: .abbreviated, time: .shortened)
        return entry.sourceApp.map { "\(time) · \($0)" } ?? time
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
    }
}

/// Large preview of one image alongside its recognized text.
struct PreviewView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    let entry: ClipEntry
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HSplitView {
                Group {
                    if let image = NSImage(contentsOf: store.imageURL(for: entry)) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        ContentUnavailableView("Image file missing", systemImage: "photo")
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    Text(entry.text.isEmpty ? "No text found" : entry.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minWidth: 180, idealWidth: 240)
            }
            HStack {
                Text("\(entry.pixelWidth) × \(entry.pixelHeight) px")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(entry.pinned ? "Unpin" : "Pin") { store.togglePin(entry); dismiss() }
                Button("Copy") { onCopy(); dismiss() }.keyboardShortcut(.defaultAction)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 480)
        .onKeyPress(.space) { dismiss(); return .handled }
    }
}
