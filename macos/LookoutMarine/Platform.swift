//  Platform.swift — the thin macOS/iOS seam.
//
//  Goal: share as much UI as possible across macOS and iOS. Everything that CAN
//  be platform-neutral (AppModel, MarinerSettings, the settings Form, the HUD,
//  zoom controls, search, and the ChartController's logic) is written against
//  these aliases/helpers instead of AppKit/UIKit directly. Only a few genuine
//  touchpoints stay `#if`-split: the backing view class, display-link creation,
//  backing scale, the native-handle kind, and raw event/gesture input.
//
//  iOS uses the `LOOKOUT_NATIVE_UIKIT_WINDOWSCENE` ABI kind (SDL can't wrap an
//  existing UIView): the chart renders in its own full-screen UIWindow behind
//  the app's transparent chrome window, and ChartUIView forwards gesture input.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import QuartzCore

#if os(macOS)
typealias PlatformView = NSView
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformView = UIView
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Lightweight log — stderr (terminal runs) + NSLog (unified log for .app runs).
func lkLog(_ message: String) {
    FileHandle.standardError.write(Data("[lookout] \(message)\n".utf8))
    NSLog("[lookout] %@", message)
}

/// The frames of the chrome controls, in the `Chrome.space` coordinate space.
/// The chromeHitRegion modifier writes them. The pass-through hosts of both
/// platforms read them.
///
/// The map is necessary because SwiftUI draws its controls without backing
/// views. A Button hit-tests as the hosting view, like empty space, so the host
/// cannot tell a control from the chart. On iOS, the accessibility scan below is
/// only a fallback: without an accessibility client, SwiftUI can build that tree
/// late or not at all. Chrome taps worked in XCUITest and failed on an iPad. The
/// frames are data written at layout time and are always available.
final class ChromeHitMap {
    static let shared = ChromeHitMap()
    private var rects: [String: (token: UUID, rect: CGRect)] = [:]
    private let lock = NSLock()

    /// Register a control's frame. Two views can hold the same id for a
    /// moment when a pick changes: the new panel appears before SwiftUI
    /// discards the old one. The token names the instance, and a zero
    /// frame is a dying view's last layout, never a control — both must
    /// not disturb a live entry.
    func set(_ id: String, token: UUID, _ rect: CGRect) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        lock.lock(); defer { lock.unlock() }
        rects[id] = (token, rect)
        // The screenshot protocol's view of the map. When a click on the
        // chrome reaches the chart, the first question is what frames the
        // map actually holds; this answers it without a debugger attached.
        if ProcessInfo.processInfo.environment["LOOKOUT_HITMAP"] != nil {
            NSLog("[hitmap] %@ = (%.0f, %.0f, %.0f, %.0f)",
                  id, rect.origin.x, rect.origin.y, rect.width, rect.height)
        }
    }

    /// Remove an entry, but only for the instance that owns it. A dying
    /// view's removal must not take the live view's entry with it.
    func remove(_ id: String, token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if rects[id]?.token == token { rects[id] = nil }
    }
    func contains(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rects.values.contains { $0.rect.contains(p) }
    }
}

#if os(iOS)
/// The chrome window: SwiftUI controls stay interactive, but touches on empty
/// chrome fall through (hitTest nil) to the input window below.
///
/// SwiftUI draws its controls WITHOUT distinct backing UIViews — a Button
/// hit-tests as the bare hosting view, identical to empty space — so the
/// canonical "pass through when the hit is the root view" trick alone would
/// drop control taps onto the chart. The chrome publishes its interactive
/// frames (ChromeHitMap); the accessibility tree is the fallback.
final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard hit === rootViewController?.view else { return hit } // real subview (sheet, keyboard, …)
        let chrome = inChromeSpace(point)
        let inMap = ChromeHitMap.shared.contains(chrome)
        // Which path answered. The map must answer. The accessibility
        // fallback has a tree to walk only when a client is attached, so a
        // control that depends on it is dead in normal use.
        if ProcessInfo.processInfo.environment["LOOKOUT_HITMAP"] != nil {
            NSLog("[hitmap] tap win(%.0f, %.0f) chrome(%.0f, %.0f) map=%d",
                  point.x, point.y, chrome.x, chrome.y, inMap ? 1 : 0)
        }
        if inMap { return hit }
        return hasInteractiveElement(at: point) ? hit : nil
    }

    /// This window's point in the chrome's coordinate space.
    ///
    /// The hosting controller's SwiftUI root is inset by the safe area.
    /// `chromeHitRegion` writes its frames in that inset space. A touch
    /// arrives here in window space, which is not inset. The conversion is
    /// necessary, or every frame in the map is wrong by the inset and a tap
    /// on a control falls outside its own rect.
    ///
    /// `ChartUIView.inChromeSpace` converts the pick point for the same
    /// reason.
    private func inChromeSpace(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - safeAreaInsets.left, y: p.y - safeAreaInsets.top)
    }

    /// True when an accessibility element with interactive traits (button,
    /// search field, text field, link, adjustable) covers `point`. Static text
    /// (the HUD readouts) deliberately does NOT count — chart gestures work
    /// across it.
    private func hasInteractiveElement(at point: CGPoint) -> Bool {
        guard let root = rootViewController?.view else { return false }
        let screenPoint = convert(point, to: screen.coordinateSpace)
        let wanted: UIAccessibilityTraits = [.button, .searchField, .link, .adjustable]
        var stack: [NSObject] = [root]
        var budget = 512 // runaway guard; the chrome tree is tiny
        while let el = stack.popLast(), budget > 0 {
            budget -= 1
            if el.isAccessibilityElement, !el.accessibilityTraits.isDisjoint(with: wanted),
               el.accessibilityFrame.contains(screenPoint) {
                return true
            }
            if let els = el.accessibilityElements as? [NSObject], !els.isEmpty {
                stack.append(contentsOf: els)
            } else {
                let n = el.accessibilityElementCount()
                if n > 0, n != NSNotFound {
                    for i in 0..<n where el.accessibilityElement(at: i) is NSObject {
                        stack.append(el.accessibilityElement(at: i) as! NSObject)
                    }
                }
            }
            if let v = el as? UIView { stack.append(contentsOf: v.subviews) }
        }
        return false
    }
}
#endif

/// The system clipboard, on both platforms.
enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

enum Platform {
    /// A display link for `view`, on both platforms.
    @MainActor
    static func makeDisplayLink(for view: PlatformView, target: Any, selector: Selector) -> CADisplayLink {
        #if os(macOS)
        return view.displayLink(target: target, selector: selector) // macOS 14+
        #else
        let link = CADisplayLink(target: target, selector: selector)
        // Without an explicit range iOS ADAPTIVELY DOWNSHIFTS the link when
        // frames miss (a chart pinch is exactly that workload) and then stays
        // low — measured as a 30-45fps cap. 60-120: with rendering on its own
        // queue, a ProMotion 120Hz boost is safe — a pool-dry nextDrawable
        // wait paces the RENDER thread only (that wait starved gesture
        // processing when rendering rode the main thread, which is why this
        // was pinned to 60 for a while).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        // Settle the "is this panel even ProMotion" question in the log: the
        // fps column can only ever approach THIS number.
        let maxHz = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        print("[lookout] display maximumFramesPerSecond = \(maxHz)")
        return link
        #endif
    }

    /// Backing scale factor (HiDPI density) for `view`.
    @MainActor
    static func backingScale(of view: PlatformView) -> CGFloat {
        #if os(macOS)
        return view.window?.backingScaleFactor ?? 2
        #else
        return view.window?.screen.scale ?? view.traitCollection.displayScale
        #endif
    }

    /// The CAMetalLayer lookout renders into: the view's own backing layer on
    /// both platforms (ChartNSView.makeBackingLayer / ChartUIView.layerClass).
    @MainActor
    static func metalLayer(of view: PlatformView) -> CAMetalLayer? {
        view.layer as? CAMetalLayer
    }
}
