//  PluginTable.swift: a plugin's declared table, as a native window.
//
//  A plugin declares a table in its manifest: a key, a title, the menu it is
//  opened from, and typed columns. The core hands the declaration over through
//  lookout_plugin_tables_json and the rows through lookout_plugin_table_rows,
//  already in the order they are to be shown. This file builds the menu item,
//  the window and the table, and knows nothing about what any plugin does.
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

#if os(macOS)
import AppKit

/// One dialog per declared table. The controller owns the window, the refresh
/// timer and the sort the mariner chose.
@MainActor
final class PluginTableWindowController: NSObject, NSWindowDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate {
    /// Every table window open now, by declaration id. A second Open finds the
    /// window it already has instead of stacking another one on it.
    private static var open: [String: PluginTableWindowController] = [:]

    /// How often the rows are re-read. The plugins feed a table at the status
    /// cadence, which is a second, so this is the same.
    private static let refreshInterval: TimeInterval = 1.0

    private let spec: PluginTableSpec
    private weak var model: AppModel?
    private var window: NSWindow!
    private var tableView: PluginNSTableView!
    private var emptyLabel: NSTextField!
    private var timer: Timer?

    private var rows: [PluginTableRow] = []
    private var sortKey: String
    private var ascending: Bool
    /// The last batch the core reported. Rows are rebuilt only when it moves,
    /// so a table nobody is feeding does not flicker once a second.
    private var seq: Int = -1
    /// False while the window is being built. Setting the declared sort on a
    /// fresh table view calls the delegate back, and there is nothing to
    /// reload into yet.
    private var ready = false

    /// Put the dialog on screen. `sortKey` is for the screenshot protocol's
    /// dev hook: the mariner picks a sort by clicking a heading, and the
    /// declared one is what everybody else gets.
    @discardableResult
    static func show(_ spec: PluginTableSpec, model: AppModel,
                     sortKey: String? = nil, ascending: Bool = true) -> PluginTableWindowController {
        if let existing = open[spec.id] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let c = PluginTableWindowController(spec: spec, model: model,
                                            sortKey: sortKey, ascending: ascending)
        open[spec.id] = c
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return c
    }

    /// True while any table window is on screen. The screenshot pass checks it.
    static var anyVisible: Bool { open.values.contains { $0.window.isVisible } }

    private init(spec: PluginTableSpec, model: AppModel, sortKey: String?, ascending: Bool) {
        self.spec = spec
        self.model = model
        let asked = sortKey.flatMap { key in spec.columns.first { $0.key == key }?.key }
        self.sortKey = asked ?? spec.sortKey
        self.ascending = asked == nil ? spec.sortAscending : ascending
        super.init()
        buildWindow()
        // The plugin is told before the first read: it builds no rows until
        // somebody is looking, so the first read would otherwise find none.
        model.controller?.setTableOpen(plugin: spec.plugin, key: spec.key, true)
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(force: false) }
        }
    }

    private func buildWindow() {
        let table = PluginNSTableView(frame: .zero)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowHeight = 22
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(activateRow)
        table.onReturn = { [weak self] in self?.activateRow() }

        for col in spec.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.key))
            c.title = col.label
            c.width = Self.width(for: col)
            c.minWidth = 40
            // The header click reorders WITHIN each band: the core sorts, this
            // only says which column and which way.
            c.sortDescriptorPrototype = NSSortDescriptor(key: col.key, ascending: true)
            if col.type.numeric {
                c.headerCell.alignment = .right
            }
            table.addTableColumn(c)
        }
        if !sortKey.isEmpty {
            table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let label = NSTextField(labelWithString: "Nothing to show yet.")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth(for: spec), height: 420),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = spec.title
        w.contentView = content
        w.contentMinSize = NSSize(width: 420, height: 200)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("plugin-table-\(spec.plugin)-\(spec.key)")
        w.center()

        window = w
        tableView = table
        emptyLabel = label
        ready = true
    }

    /// A first width per column type. The mariner resizes from there and the
    /// window frame autosaves it.
    private static func width(for col: PluginTableColumn) -> CGFloat {
        switch col.type {
        case .text: return 150
        case .flag: return 84
        default: return 84
        }
    }

    private static func windowWidth(for spec: PluginTableSpec) -> CGFloat {
        let sum = spec.columns.reduce(CGFloat(0)) { $0 + width(for: $1) }
        // The gap between columns and the table's own insets are not in the
        // column widths, so the window carries them too or the last column
        // opens under the window edge.
        return min(max(sum + CGFloat(spec.columns.count) * 4 + 90, 480), 1100)
    }

    // MARK: Reading the core

    private func reload(force: Bool) {
        guard ready, let c = model?.controller else { return }
        guard let batch = c.tableRows(plugin: spec.plugin, key: spec.key,
                                      sortKey: sortKey, ascending: ascending,
                                      columns: spec.columns.count)
        else {
            // The plugin has gone, and the table with it. Better an empty
            // dialog than a picture nobody is keeping up to date.
            seq = -1
            guard !rows.isEmpty else { return }
            rows = []
            tableView.reloadData()
            emptyLabel.isHidden = false
            return
        }
        if !force && batch.seq == seq { return }
        seq = batch.seq

        // The mariner's place in the table is theirs. The selection is kept by
        // row id, not by index, so a row arriving above it does not move it.
        let selected = tableView.selectedRow >= 0 && tableView.selectedRow < rows.count
            ? rows[tableView.selectedRow].id : nil
        rows = batch.rows
        tableView.reloadData()
        if let selected, let i = rows.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !rows.isEmpty
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let i = spec.columns.firstIndex(where: { $0.key == tableColumn.identifier.rawValue }),
              row < rows.count
        else { return nil }
        let col = spec.columns[i]

        let id = tableColumn.identifier
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        let cell = rows[row].cell(i)
        field.stringValue = PluginTableFormat.text(cell, col.type)
        field.alignment = col.type.numeric ? .right : .left
        // A cell the plugin never sent is greyed: the mariner can tell a
        // value that is missing from one that is small.
        switch cell {
        case .empty: field.textColor = .tertiaryLabelColor
        default: field.textColor = col.type == .flag ? Self.flagColor(cell) : .labelColor
        }
        return field
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = PluginTableRowView()
        view.tint = row < rows.count ? Self.rowTint(rows[row], spec: spec) : nil
        return view
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        ascending = d.ascending
        reload(force: true)
    }

    /// The row the mariner opened: centre the chart on it and pin its bubble.
    /// Entirely shell-side: the plugin is not told, and does not need to be.
    @objc private func activateRow() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activate(row: row)
    }

    private func activate(row: Int) {
        // A table that declared no `at` has no rows to find on the chart, and
        // one that did may still hold a row nobody has heard a position from.
        guard spec.locatable, row >= 0, row < rows.count else { return }
        guard let lat = rows[row].lat, let lon = rows[row].lon else { return }
        model?.revealOnChart(lon: lon, lat: lat)
    }

    /// Shut the dialog. Used where it was opened only to make the plugin build
    /// its rows, and the rows rather than the dialog were what was wanted.
    func dismiss() { window.close() }

    /// Open the top row, for the screenshot protocol's dev hook. It is the
    /// same path a double-click or a Return takes.
    func activateTopRow() {
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        activate(row: 0)
    }

    /// The colour of a row, from its flag column. Alarm is the chart's own
    /// danger red; a warning is amber. A row with no flag is left alone.
    private static func rowTint(_ row: PluginTableRow, spec: PluginTableSpec) -> NSColor? {
        for (i, col) in spec.columns.enumerated() where col.type == .flag {
            switch row.cell(i).string?.lowercased() {
            case "alarm": return NSColor.systemRed.withAlphaComponent(0.22)
            case "warning": return NSColor.systemOrange.withAlphaComponent(0.20)
            default: continue
            }
        }
        return nil
    }

    private static func flagColor(_ cell: PluginCell) -> NSColor {
        switch cell.string?.lowercased() {
        case "alarm": return .systemRed
        case "warning": return .systemOrange
        default: return .labelColor
        }
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        model?.controller?.setTableOpen(plugin: spec.plugin, key: spec.key, false)
        Self.open.removeValue(forKey: spec.id)
    }
}

/// Return opens the selected row, the way double-click does. AppKit sends the
/// double action for the mouse only.
final class PluginNSTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        if key == "\r" || key == "\u{3}" {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A row that carries a plugin's flag colour behind it, and still draws the
/// system's own selection over it.
final class PluginTableRowView: NSTableRowView {
    var tint: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint else { return }
        tint.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

#endif
