import AppKit
import SwiftUI

/// Takes audio dragged onto the Note Browser from Finder (file URLs) or
/// Voice Memos (file promises), #703. It lies over the whole window: clicks,
/// scrolls, and hovers pass through to the views below, and only drags stop
/// here, so a drop over the transcript imports instead of pasting a path.
struct AudioFileDropTarget: NSViewRepresentable {
    var isEnabled: Bool
    /// The drop zone to show, or nil when no file is being dragged here.
    var onTargetChange: (AudioFileDrop.Target?) -> Void
    /// The file to import, the drop's own folder to remove once the file is
    /// copied (promised files only), and how many other dropped files were left out.
    var onDrop: (_ fileURL: URL, _ promiseFolder: URL?, _ skippedCount: Int) -> Void
    /// A promised file that never arrived, or arrived but isn't audio Quill can import.
    var onDropFailed: (AudioFileDropFailure) -> Void

    func makeNSView(context: Context) -> AudioFileDropTargetView {
        let view = AudioFileDropTargetView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AudioFileDropTargetView, context: Context) {
        view.isEnabled = isEnabled
        view.onTargetChange = onTargetChange
        view.onDrop = onDrop
        view.onDropFailed = onDropFailed
        if !isEnabled {
            // Not during the view update that turned drops off.
            DispatchQueue.main.async { view.clearTarget() }
        }
    }
}

final class AudioFileDropTargetView: NSView {
    var isEnabled = true
    var onTargetChange: (AudioFileDrop.Target?) -> Void = { _ in }
    var onDrop: (URL, URL?, Int) -> Void = { _, _, _ in }
    var onDropFailed: (AudioFileDropFailure) -> Void = { _ in }

    private var currentTarget: AudioFileDrop.Target?
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private enum DraggedItem {
        case file(URL)
        case promise(NSFilePromiseReceiver)

        var item: AudioFileDrop.Item {
            switch self {
            case .file(let url): return .file(url)
            case .promise(let receiver): return .promise(typeIdentifiers: receiver.fileTypes)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(promiseTypes + [.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Mouse, scroll, and gesture events go to the views below. AppKit finds
    /// a drag's destination by hit testing too, outside those events, so then
    /// this view answers. An event older than half a second is a leftover from
    /// before the drag, not one being handled now.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent,
           ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5,
           Self.passThroughEventTypes.contains(event.type) {
            return nil
        }
        return super.hitTest(point)
    }

    private static let passThroughEventTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
        .scrollWheel, .magnify, .swipe, .rotate, .beginGesture, .endGesture,
        .smartMagnify, .pressure, .tabletPoint, .tabletProximity, .directTouch
    ]

    override func isAccessibilityElement() -> Bool {
        false
    }

    func clearTarget() {
        guard currentTarget != nil else { return }
        currentTarget = nil
        onTargetChange(nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearTarget()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearTarget()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isEnabled && AudioFileDrop.target(for: draggedItems(sender).map(\.item)) == .importable
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearTarget()
        let dragged = draggedItems(sender)
        guard isEnabled, let choice = AudioFileDrop.choice(from: dragged.map(\.item)) else {
            return false
        }
        switch dragged[choice.itemIndex] {
        case .file(let url):
            onDrop(url, nil, choice.skippedCount)
        case .promise(let receiver):
            receivePromisedFile(from: receiver, skippedCount: choice.skippedCount)
        }
        return true
    }

    private func updateTarget(for sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled else {
            clearTarget()
            return []
        }
        let target = AudioFileDrop.target(for: draggedItems(sender).map(\.item))
        if target != currentTarget {
            currentTarget = target
            onTargetChange(target)
        }
        return target == .importable ? .copy : []
    }

    private func draggedItems(_ sender: NSDraggingInfo) -> [DraggedItem] {
        var items: [DraggedItem] = []
        sender.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSFilePromiseReceiver.self, NSURL.self],
            searchOptions: [.urlReadingFileURLsOnly: true]
        ) { draggingItem, _, _ in
            switch draggingItem.item {
            case let receiver as NSFilePromiseReceiver:
                items.append(.promise(receiver))
            case let url as URL:
                items.append(.file(url))
            default:
                break
            }
        }
        return items
    }

    /// Voice Memos writes the recording into a folder of this drop's own.
    /// Only the first promised file is imported.
    private func receivePromisedFile(from receiver: NSFilePromiseReceiver, skippedCount: Int) {
        guard let folder = try? AudioFileDrop.makePromiseFolder() else {
            onDropFailed(.notReceived)
            return
        }
        var isHandled = false
        receiver.receivePromisedFiles(
            atDestination: folder,
            options: [:],
            operationQueue: promiseQueue
        ) { [weak self] fileURL, error in
            DispatchQueue.main.async {
                guard !isHandled else { return }
                isHandled = true
                // Recording or another import may have started while the file was written.
                guard let self, self.isEnabled else {
                    AudioFileDrop.removePromiseFolder(folder)
                    return
                }
                guard error == nil else {
                    AudioFileDrop.removePromiseFolder(folder)
                    self.onDropFailed(.notReceived)
                    return
                }
                guard AudioFileDrop.isImportable(fileURL: fileURL) else {
                    AudioFileDrop.removePromiseFolder(folder)
                    self.onDropFailed(.notImportable)
                    return
                }
                self.onDrop(fileURL, folder, skippedCount)
            }
        }
    }
}

enum AudioFileDropFailure {
    case notReceived
    case notImportable
}

/// The drop zone over the Note Browser while audio is dragged onto it.
struct AudioFileDropZone: View {
    let target: AudioFileDrop.Target

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: QuillRadius.radius12)
                .fill(.background.opacity(reduceTransparency ? 0.96 : 0.82))
            RoundedRectangle(cornerRadius: QuillRadius.radius12)
                .strokeBorder(
                    tint,
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
            VStack(spacing: QuillSpacing.space8) {
                Image(systemName: target == .importable ? "waveform.badge.plus" : "nosign")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text("Supported formats: FLAC, MP3, MP4, MPEG, MPGA, M4A, OGG, WAV, WEBM")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(QuillSpacing.space24)
        }
        .padding(QuillSpacing.space10)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        target == .importable ? .accentColor : .secondary
    }

    private var title: LocalizedStringKey {
        target == .importable ? "Drop to Import Audio" : "Quill Can’t Import This File"
    }
}
