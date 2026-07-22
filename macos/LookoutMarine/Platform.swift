//  Platform.swift — the thin macOS/iOS seam.
//
//  Goal: share as much UI as possible across macOS and iOS. Everything that CAN
//  be platform-neutral (AppModel, MarinerSettings, the settings Form, the HUD,
//  zoom controls, search, and the ChartController's logic) is written against
//  these aliases/helpers instead of AppKit/UIKit directly. Only a few genuine
//  touchpoints stay `#if`-split: the backing view class, display-link creation,
//  backing scale, the native-handle kind, and raw event/gesture input.
//
//  Phase 1 builds the macOS target. The iOS branches are scaffolded and marked;
//  bringing up an iOS target additionally needs (a) a `LOOKOUT_NATIVE_UIKIT_VIEW`
//  ABI kind backed by a CAMetalLayer UIView, and (b) UIGestureRecognizer input.

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
}
