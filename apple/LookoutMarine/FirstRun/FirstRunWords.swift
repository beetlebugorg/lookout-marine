//  FirstRunWords.swift: the strings that differ by platform.
//
//  A Mac accepts a drop on its window and a phone does not, and each names the
//  device the mariner holds. Keeping them here leaves each step as one page of
//  prose instead of a run of #if.

import Foundation
#if os(iOS)
import UIKit
#endif

enum FirstRun {
    /// The name of the device the mariner holds.
    static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// The welcome page's promise, which names the device.
    static var promise: String {
        "Official charts, rendered live on your \(deviceName)."
    }

    /// What the Files source accepts. The Mac also mentions dropping.
    static var filesBlurb: String {
        #if os(macOS)
        return "A prepared .pmtiles chart, or a folder of S-57 cells. Or drop either anywhere in this window."
        #else
        return "A prepared .pmtiles chart, or a folder of S-57 cells, from the Files app."
        #endif
    }
}
