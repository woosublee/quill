import AppKit
import SwiftUI

final class FixedIntrinsicHostingView<Content: View>: NSHostingView<Content> {
    private var fixedIntrinsicContentSize: NSSize

    init(rootView: Content, size: NSSize) {
        self.fixedIntrinsicContentSize = size
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        self.fixedIntrinsicContentSize = .zero
        super.init(coder: coder)
        sizingOptions = []
    }

    @MainActor @preconcurrency required dynamic init(rootView: Content) {
        self.fixedIntrinsicContentSize = .zero
        super.init(rootView: rootView)
        sizingOptions = []
    }

    override var intrinsicContentSize: NSSize {
        fixedIntrinsicContentSize
    }

    func setFixedIntrinsicContentSize(_ size: NSSize) {
        fixedIntrinsicContentSize = size
        invalidateIntrinsicContentSize()
    }
}

final class FixedHostingContainer<Content: View>: NSView {
    private let hostingView: FixedIntrinsicHostingView<Content>

    init(rootView: Content, size: NSSize) {
        self.hostingView = FixedIntrinsicHostingView(rootView: rootView, size: size)
        super.init(frame: NSRect(origin: .zero, size: size))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        return nil
    }

    func setFixedContentSize(_ size: NSSize) {
        setFrameSize(size)
        hostingView.frame = bounds
        hostingView.setFixedIntrinsicContentSize(size)
    }
}
