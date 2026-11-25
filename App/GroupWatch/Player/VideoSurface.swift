import AppKit
import SwiftUI

/// Hosts mpv's Metal layer and keeps its drawable matched to the view's pixels.
final class VideoLayerView: NSView {
    private let metalLayer: MPVMetalLayer

    init(layer: MPVMetalLayer) {
        metalLayer = layer
        super.init(frame: .zero)
        // Layer-hosting view: assign the layer before turning on wantsLayer.
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        updateDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawable()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawable()
    }

    private func updateDrawable() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }

    // Clicks and drags belong to the SwiftUI overlay above.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VideoSurface: NSViewRepresentable {
    let player: MPVPlayer

    func makeNSView(context: Context) -> VideoLayerView {
        VideoLayerView(layer: player.layer)
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}
