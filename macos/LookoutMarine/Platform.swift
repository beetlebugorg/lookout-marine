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

#if os(iOS)
/// The chrome window: SwiftUI controls stay interactive, but touches on empty
/// chrome fall through (hitTest nil) to the input window below.
///
/// SwiftUI draws its controls WITHOUT distinct backing UIViews — a Button
/// hit-tests as the bare hosting view, identical to empty space — so the
/// canonical "pass through when the hit is the root view" trick alone would
/// drop control taps onto the chart. The accessibility tree, however, does
/// carry every control with an accurate screen frame; consult it to decide.
final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard hit === rootViewController?.view else { return hit } // real subview (sheet, keyboard, …)
        return hasInteractiveElement(at: point) ? hit : nil
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

enum Platform {
    /// A display link for `view`, on both platforms.
    @MainActor
    static func makeDisplayLink(for view: PlatformView, target: Any, selector: Selector) -> CADisplayLink {
        #if os(macOS)
        return view.displayLink(target: target, selector: selector) // macOS 14+
        #else
        return CADisplayLink(target: target, selector: selector)
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
