//  PluginTableModel.swift: a plugin's declared table, and its rows.
//
//  A plugin declares a table in its manifest: a key, a title, the menu it is
//  opened from, and typed columns. The core hands the declaration over through
//  lookout_tables_read and the rows through lookout_table_rows_read, already in
//  the order they are to be shown. Nothing here knows what any plugin does.
//
//  UNITS ARE THE SHELL'S. The column type says what a number means: distance
//  is metres, speed metres per second, bearing degrees true, duration seconds,
//  and every one is formatted here, in the units of the sea. That is the
//  reverse of the pick report, and it is what lets the core sort a column
//  numerically while the mariner reads knots and nautical miles.
//
//  THE ORDER IS THE PLUGIN'S FIRST. Every row carries a band, and the core
//  sorts within a band and never across one. A header click therefore reorders
//  the vessels under an alarmed one and never moves it off the top line.
//
//  A null cell is a dash. Never heard and heard as zero are different
//  values, and the table says which one it has.

import Foundation

// MARK: - The declaration

enum PluginColumnType: String {
    case distance, speed, bearing, duration, number, text, flag

    /// True when the column holds a number, which is what gets right aligned
    /// and what the mariner scans down a column of.
    var numeric: Bool {
        switch self {
        case .distance, .speed, .bearing, .duration, .number: return true
        case .text, .flag: return false
        }
    }

    /// A type this build does not know shows as text. The core refuses a
    /// declaration naming one, so this is the newer-core case rather than the
    /// bad-plugin case.
    init(_ t: lookout_column_type) {
        switch t {
        case LOOKOUT_COLUMN_DISTANCE: self = .distance
        case LOOKOUT_COLUMN_SPEED:    self = .speed
        case LOOKOUT_COLUMN_BEARING:  self = .bearing
        case LOOKOUT_COLUMN_DURATION: self = .duration
        case LOOKOUT_COLUMN_NUMBER:   self = .number
        case LOOKOUT_COLUMN_FLAG:     self = .flag
        default:                      self = .text
        }
    }
}

struct PluginTableColumn {
    let key: String
    let label: String
    let type: PluginColumnType

    init(key: String, label: String, type: PluginColumnType) {
        self.key = key
        self.label = label
        self.type = type
    }

    init(_ c: lookout_table_column) {
        self.init(key: String(cString: c.key),
                  label: String(cString: c.label),
                  type: PluginColumnType(c.type))
    }
}

/// One table a plugin declares. `id` is what a menu item carries.
struct PluginTableSpec: Identifiable {
    let plugin: String
    let key: String
    let title: String
    let menu: String
    let columns: [PluginTableColumn]
    let sortKey: String
    let sortAscending: Bool
    /// True when the declaration's `at` named a position, so a row can be
    /// found on the chart.
    let locatable: Bool

    var id: String { "\(plugin)/\(key)" }

    /// One declaration of a read, with the columns already read out of it.
    /// Every string is copied, so the spec outlives the read it came from.
    init(_ t: lookout_table, columns: [PluginTableColumn]) {
        self.plugin = String(cString: t.plugin)
        self.key = String(cString: t.key)
        self.title = String(cString: t.title)
        self.menu = String(cString: t.menu)
        self.columns = columns
        self.sortKey = String(cString: t.sort_key)
        self.sortAscending = t.sort_ascending != 0
        // The core sets both halves together, so one of them answers it.
        self.locatable = !String(cString: t.at_lat).isEmpty
    }
}

// MARK: - The rows

enum PluginCell {
    case empty
    case number(Double)
    case text(String)

    /// `kind` is what the plugin sent, which is not always what the column
    /// type asks for: a string in a distance column stays a string and shows
    /// as one.
    init(_ c: lookout_table_cell) {
        switch c.kind {
        case LOOKOUT_CELL_NUMBER: self = .number(c.number)
        case LOOKOUT_CELL_TEXT:   self = .text(String(cString: c.text))
        default:                  self = .empty
        }
    }

    var string: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

struct PluginTableRow {
    let id: String
    let band: Int
    let lat: Double?
    let lon: Double?
    let cells: [PluginCell]

    /// One row of a read, with its cells already read out of it. A row that
    /// carried fewer cells than the table has columns is padded, so it still
    /// lines up under the headings.
    init(_ r: lookout_table_row, cells: [PluginCell], columns: Int) {
        self.id = String(cString: r.id)
        self.band = Int(r.band)
        self.lon = r.located != 0 ? r.lon : nil
        self.lat = r.located != 0 ? r.lat : nil
        var padded = cells
        while padded.count < columns { padded.append(.empty) }
        self.cells = padded
    }

    func cell(_ i: Int) -> PluginCell { i < cells.count ? cells[i] : .empty }
}

/// What a cell says, in the mariner's units.
enum PluginTableFormat {
    /// A cell the plugin did not send. Not a zero, and it never reads as one.
    static let missing = "—"

    static func text(_ cell: PluginCell, _ type: PluginColumnType) -> String {
        switch cell {
        case .empty:
            return missing
        case .text(let s):
            return type == .flag ? s.uppercased() : s
        case .number(let v):
            guard v.isFinite else { return missing }
            switch type {
            // Under a tenth of a mile the metres are what matters: a CPA of
            // "0.07 nm" tells a mariner far less than "124 m".
            case .distance:
                return v < 185.2 ? "\(Int(v.rounded())) m"
                                 : String(format: "%.2f nm", v / 1852)
            case .speed:
                return String(format: "%.1f kn", v * 3600 / 1852)
            case .bearing:
                let d = v.truncatingRemainder(dividingBy: 360)
                return String(format: "%03.0f°", d < 0 ? d + 360 : d)
            case .duration:
                return duration(v)
            case .number:
                return String(format: "%g", v)
            case .text, .flag:
                return String(format: "%g", v)
            }
        }
    }

    /// Seconds as a mariner counts them down: minutes and seconds, and hours
    /// once there are any.
    static func duration(_ seconds: Double) -> String {
        let negative = seconds < 0
        let total = Int(abs(seconds).rounded())
        let sign = negative ? "-" : ""
        if total >= 3600 {
            return String(format: "%@%d:%02d:%02d", sign, total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%@%d:%02d", sign, total / 60, total % 60)
    }
}
