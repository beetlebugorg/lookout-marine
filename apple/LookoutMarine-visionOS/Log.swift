//
//  One log line shape, so the app's own lines can be told from everything else
//  in the device log:
//
//      xcrun simctl spawn booted log show --last 5m \
//        --predicate 'processImagePath CONTAINS "LookoutMarine"'
//

import Foundation
import os

private let logger = Logger(subsystem: "org.beetlebug.lookout-marine-visionos", category: "table")

func lkLog(_ message: String) {
    logger.log("lookout: \(message, privacy: .public)")
}
