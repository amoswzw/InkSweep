import AppKit
import SwiftUI

/// Owns the menu bar item. A plain AppKit status item, not SwiftUI's
/// MenuBarExtra: menu bar managers such as InkBar open hidden items with an
/// accessibility press, and MenuBarExtra's window panel ignores that press.
/// A button with an action answers it like a click.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let host: NSHostingController<AnyView>
    private var floating: FloatingPanel?

    init(model: AppModel) {
        let closer = Closer()
        host = NSHostingController(rootView: AnyView(
            MenuBarPanel(model: model, close: { closer.close?() })
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        ))
        host.sizingOptions = .preferredContentSize
        super.init()
        closer.close = { [weak self] in self?.dismiss() }
        popover.behavior = .transient
        if let button = item.button {
            button.image = MenuBarPanel.icon
            button.toolTip = "InkSweep"
            button.setAccessibilityLabel("InkSweep")
            button.target = self
            button.action = #selector(toggle(_:))
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown || floating?.isVisible == true {
            dismiss()
            return
        }
        guard let button = item.button else { return }
        if Self.isInMenuBar(button) {
            floating?.contentViewController = nil
            popover.contentViewController = host
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            // Concealed by a menu bar manager (InkBar presses hidden items in
            // place unless the app is notarized): there is nothing on screen
            // to hang a popover from, so float the panel under the pointer.
            showFloating()
        }
    }

    /// Development aid: open the panel as if the menu bar item was clicked
    /// and return its window (used by the `-InkSweepShot` screenshot mode).
    func debugShowPanel() -> NSWindow? {
        toggle(nil)
        return popover.contentViewController?.view.window ?? floating
    }

    private func dismiss() {
        popover.performClose(nil)
        floating?.orderOut(nil)
    }

    /// True when the button sits in a screen's menu bar strip, where a
    /// popover can be anchored to it.
    private static func isInMenuBar(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, window.isVisible else { return false }
        return NSScreen.screens.contains { screen in
            screen.frame.intersects(window.frame) && window.frame.minY >= screen.visibleFrame.maxY - 2
        }
    }

    private func showFloating() {
        popover.contentViewController = nil
        let panel = floating ?? FloatingPanel()
        floating = panel
        panel.contentViewController = host
        let size = host.view.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let x = min(max(mouse.x - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let y = screen.visibleFrame.maxY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private final class Closer { var close: (() -> Void)? }
}

/// The panel shown when the status item is not on screen: borderless, above
/// the menu bar's level like a menu, gone when it loses focus or on Esc.
private final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            statusItem = StatusItemController(model: AppModel.shared)
            if let item = statusItem { Self.runShotModeIfAsked(statusItem: item) }
        }
    }

    /// The menu bar item keeps InkSweep useful with its window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Development flag `-InkSweepShot <path>`: after `-InkSweepShotDelay`
    /// seconds (default 8) capture the app's own window — capturing a window
    /// the app owns needs no Screen Recording permission — write a PNG and
    /// quit. With `-InkSweepShotPanel 1` it shoots the menu bar panel instead.
    /// Used to produce the README screenshots.
    private static func runShotModeIfAsked(statusItem: StatusItemController) {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "InkSweepShot") else { return }
        let delay = defaults.double(forKey: "InkSweepShotDelay")
        let wantsPanel = defaults.bool(forKey: "InkSweepShotPanel")
        let out = URL(fileURLWithPath: path)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
            var window: NSWindow?
            if wantsPanel {
                window = statusItem.debugShowPanel()
                try? await Task.sleep(nanoseconds: 800_000_000)
            } else {
                window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
            }
            if let window {
                // A window launched at the command line can cascade partly
                // off-screen; the compositor paints off-screen pixels black.
                if !wantsPanel {
                    window.makeKeyAndOrderFront(nil)
                    if let screen = window.screen ?? NSScreen.main {
                        let f = window.frame
                        window.setFrameOrigin(NSPoint(
                            x: screen.visibleFrame.midX - f.width / 2,
                            y: screen.visibleFrame.midY - f.height / 2))
                    }
                }
                capture(window, to: out)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    @MainActor private static func capture(_ window: NSWindow, to url: URL) {
        // Offscreen render of the content view: no Screen Recording permission
        // needed and no dependence on the window being composited on screen.
        guard let content = window.contentView else { return }
        let rect = content.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(rect.width) * 2,
                                         pixelsHigh: Int(rect.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = rect.size
        content.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
