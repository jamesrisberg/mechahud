import AppKit
import HUDKit
import SwiftUI
import WebKit
import MechaHUDKit

/// Owns the glass panel: a `.windowed` `HUDPanelWindow` (a normal window: clicking it
/// activates MechaHUD, other windows can cover it; compact and parked too, since it is the
/// same window) whose content is a `HUDGlassView` hosting the SwiftUI tree. Implements the window side of the MacHUD contract for `MechaHUDHost`.
@MainActor
final class PanelController: NSObject, PanelPresenting, NSWindowDelegate {
    let window: DashboardPanelWindow
    let ui = PanelUIState()
    private let bridge: BridgeClient
    private let settings: AppSettings
    /// The full-mode frame; compact mode keeps its top-left corner and width.
    private var fullFrame: CGRect
    private var animating = false
    /// The frame the panel parked from (updated by `panel frame` while parked).
    private var parkRest: CGRect?
    /// True from `dismiss` until its fade-out finishes; a `present` in between clears it.
    private var dismissing = false

    /// Called when the user changes mode or hides from the panel's own buttons.
    var onUserMode: ((HUDPanelMode) -> Void)?
    var onUserHide: (() -> Void)?

    init(bridge: BridgeClient, settings: AppSettings) {
        self.bridge = bridge
        self.settings = settings
        let saved = settings.panelFrame
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PanelMetrics.fullSize
        let initial = saved.flatMap { $0.width >= 320 ? $0 : nil }
            ?? CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        fullFrame = HUDParking.restFrame(for: initial, in: screen)

        window = DashboardPanelWindow(contentRect: fullFrame, behavior: .windowed)
        window.styleMask.insert(.resizable)
        window.minSize = CGSize(width: 420, height: PanelMetrics.compactHeight)
        window.identifier = NSUserInterfaceItemIdentifier("xyz.machud.mechahud.dashboard")
        window.title = "MechaHUD"
        super.init()
        window.delegate = self
        // Escape dismisses (hides) the panel; it never quits.
        window.onCancel = { [weak self] in self?.onUserHide?() }

        let glass = HUDGlassView(frame: CGRect(origin: .zero, size: fullFrame.size), style: .panel)
        glass.autoresizingMask = [.width, .height]
        let root = PanelRootView(bridge: bridge, ui: ui,
                                 setMode: { [weak self] in self?.onUserMode?($0) },
                                 hide: { [weak self] in self?.onUserHide?() })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        window.contentView = glass
    }

    // MARK: PanelPresenting

    func present(mode: HUDPanelMode, parking: ParkingSpot, transition: HUDPanelTransition) {
        // Summoned mid-dismiss: the fade-out's completion orders the window out, so the
        // completion re-shows it (see `dismiss`); until then place it as if it were hidden.
        dismissing = false
        let wasParked = ui.mode == .parked && window.isVisible
        ui.mode = mode
        let screen = HUDParking.screenFrame(for: fullFrame)
        switch mode {
        case .parked:
            if !window.isVisible { window.setFrame(compactFrame, display: false); window.orderFrontRegardless() }
            // Park from where the panel rests; an already parked panel (MacHUD naming a new
            // edge or peek) moves from that rest frame, not from its off-screen one.
            if !wasParked { parkRest = window.frame }
            let rest = parkRest ?? window.frame
            animating = true
            HUDAnimation.conceal(window, to: parking.offScreenFrame(for: rest, in: HUDParking.screenFrame(for: rest)),
                                 fade: false) { [weak self] in self?.animating = false }
        case .full, .compact:
            let target = HUDParking.restFrame(for: mode == .full ? fullFrame : compactFrame, in: screen)
            animating = true
            if window.isVisible {
                HUDAnimation.reveal(window, to: target) { [weak self] in self?.animating = false }
            } else {
                window.setFrame(target, display: false)
                HUDAnimation.fadeIn(window)
                animating = false
            }
            // Click/summon: bring it forward and activate MechaHUD; hover: only order it in.
            window.activateOnShow(transition)
        }
    }

    func dismiss() {
        guard window.isVisible, !dismissing else { return }
        dismissing = true
        HUDAnimation.fadeOut(window) { [weak self] in
            guard let self else { return }
            if self.dismissing { self.dismissing = false; return }
            // A show arrived during the fade: HUDAnimation has just ordered the window out.
            self.window.alphaValue = 1
            self.window.orderFrontRegardless()
        }
    }

    func setFrame(_ frame: CGRect) {
        switch ui.mode {
        case .full, .parked: fullFrame = frame
        case .compact: fullFrame = CGRect(x: frame.minX, y: frame.maxY - fullFrame.height, width: frame.width, height: fullFrame.height)
        }
        save()
        guard ui.mode != .parked else { parkRest = fullFrame; return }
        animating = true
        window.setFrame(ui.mode == .full ? fullFrame : compactFrame, display: true)
        animating = false
    }

    func openSession(_ sessionKey: String) {
        ui.selectedKey = sessionKey
        ui.showingSettings = false
    }

    /// Debug rendering for `action snapshot`: the SwiftUI layers via `cacheDisplay`, with the
    /// out-of-process WKWebView composited from `takeSnapshot`. The behind-window blur of the
    /// glass does not render this way, so the backdrop comes out dark.
    func snapshot(to path: String, done: @escaping (String?) -> Void) {
        // Render the SwiftUI layer only: the glass backdrop rasterizes as a white sheet.
        guard let content = window.contentView,
              let layer = content.subviews.first(where: { $0 is NSHostingView<PanelRootView> }) ?? content.subviews.last,
              let rep = layer.bitmapImageRepForCachingDisplay(in: layer.bounds) else {
            done("no content view"); return
        }
        layer.cacheDisplay(in: layer.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        func write(_ img: NSImage) {
            guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
                  let png = bmp.representation(using: .png, properties: [:]) else { done("encode failed"); return }
            do { try png.write(to: URL(fileURLWithPath: path)); done(nil) } catch { done("\(error)") }
        }
        let web = Self.findWebView(in: content)
        let webRect = web.map { $0.convert($0.bounds, to: content) } ?? .zero
        let composite: (NSImage?) -> Void = { webImage in
            MainActor.assumeIsolated {
                let out = NSImage(size: content.bounds.size)
                out.lockFocus()
                NSColor(white: 0.12, alpha: 1).setFill()
                CGRect(origin: .zero, size: content.bounds.size).fill()
                image.draw(in: CGRect(origin: .zero, size: content.bounds.size))
                webImage?.draw(in: webRect)
                out.unlockFocus()
                write(out)
            }
        }
        guard let web else { composite(nil); return }
        web.takeSnapshot(with: nil) { img, _ in composite(img) }
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let w = findWebView(in: sub) { return w } }
        return nil
    }

    private var compactFrame: CGRect {
        let h = PanelMetrics.compactHeight
        return CGRect(x: fullFrame.minX, y: fullFrame.maxY - h, width: fullFrame.width, height: h)
    }

    // MARK: Tracking user moves/resizes

    func windowDidMove(_ notification: Notification) { track() }
    func windowDidResize(_ notification: Notification) { track() }

    private func track() {
        guard !animating, window.isVisible else { return }
        let f = window.frame
        switch ui.mode {
        case .full: fullFrame = f
        case .compact: fullFrame = CGRect(x: f.minX, y: f.maxY - fullFrame.height, width: f.width, height: fullFrame.height)
        case .parked: return
        }
        save()
    }

    private func save() {
        settings.panelFrame = fullFrame
    }
}

/// The dashboard panel: Escape (`cancelOperation`) dismisses it, when nothing inside the
/// panel (a text field, the web page) handled the key first.
final class DashboardPanelWindow: HUDPanelWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
