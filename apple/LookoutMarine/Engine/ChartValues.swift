//  ChartValues.swift — the values the chart reports, as plain types.
//
//  These are snapshots the core hands out and the chrome reads. They are named
//  here rather than inside ChartController so that the seams in ChartEngine.swift
//  can name them without naming the class behind them, and so a test can make
//  one without a chart handle.

import Foundation

/// One raster chart set, as the engine groups them.
///
/// `shown` is the set's own state, not "drawn over this view": that is what
/// gets saved, and a coast off screen still has an answer.
struct RasterSet: Identifiable, Equatable {
    let id: Int
    let name: String
    let inView: Bool
    let shown: Bool
}

/// One of the mariner's own marks, copied out of the core. The core owns the
/// list and the file it lives in; this is a snapshot for the UI.
struct ChartMarker: Identifiable, Equatable {
    let id: UInt64
    let lon: Double
    let lat: Double
    let name: String
    let droppedAt: Date
}

/// What the position readout may say. The core decides: `live` carries a fix
/// inside its freshness window, `lost` means a source published once and has
/// stopped, `none` means nothing ever has.
enum FixState: Int { case none = 0, lost = 1, live = 2 }
