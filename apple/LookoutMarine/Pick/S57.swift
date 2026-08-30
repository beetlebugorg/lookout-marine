//  S57.swift — the attribute payload, as the cell states it.
//
//  An S-57 cell gives a flat object of acronym and value. S-101 does not: a
//  complex attribute has sub-attributes, so a value can be an object or an
//  array. The rows therefore have a depth, and a complex attribute becomes a
//  heading with its parts indented under it.
//
//  This is the fold under the decoded report, and the clipboard copy, which is
//  how a chart problem gets reported.

import Foundation


/// Attribute payload helpers.
///
/// An S-57 cell gives a flat object of acronym and value. S-101 does not: a
/// complex attribute carries sub-attributes, so a value can be an object or an
/// array. The rows therefore carry a depth, and a complex attribute becomes a
/// heading with its parts indented under it.
enum S57 {
    struct Row: Identifiable {
        let name: String
        let value: String
        let depth: Int
        var id: String { "\(depth)/\(name)/\(value)" }

        /// A cell can point at a text file or a picture beside it, such as
        /// US348MDE.TXT. S-57 names it in TXTDSC, NTXTDS or PICREP; S-101 puts
        /// it in a fileReference. The bake does not carry those files, so the
        /// report states the reference and marks it as a file.
        var fileReference: Bool {
            ["TXTDSC", "NTXTDS", "PICREP", "fileReference"].contains(name)
                && !value.isEmpty
        }

        var isPicture: Bool {
            let lower = value.lowercased()
            return [".tif", ".tiff", ".jpg", ".jpeg", ".png"].contains { lower.hasSuffix($0) }
        }
    }

    static func attributes(of json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var rows: [Row] = []
        append(root, name: nil, depth: 0, into: &rows)
        return rows
    }

    /// Rows from an already-parsed payload — the envelope's raw half.
    static func rows(of any: Any?) -> [Row] {
        guard let any else { return [] }
        var rows: [Row] = []
        append(any, name: nil, depth: 0, into: &rows)
        return rows
    }

    private static func append(_ node: Any, name: String?, depth: Int, into rows: inout [Row]) {
        switch node {
        case let object as [String: Any]:
            if let name { rows.append(Row(name: name, value: "", depth: depth)) }
            for key in object.keys.sorted() {
                append(object[key] ?? "", name: key, depth: name == nil ? depth : depth + 1, into: &rows)
            }
        case let list as [Any]:
            if let name { rows.append(Row(name: name, value: "", depth: depth)) }
            for item in list {
                append(item, name: nil, depth: depth + 1, into: &rows)
            }
        default:
            rows.append(Row(name: name ?? "", value: text(of: node), depth: depth))
        }
    }

    private static func text(of node: Any) -> String {
        if let s = node as? String { return s }
        if let n = node as? NSNumber { return n.stringValue }
        return String(describing: node)
    }

    /// The attribute names that carry something to read.
    static let informational: Set<String> = [
        "INFORM", "NINFOM", "TXTDSC", "NTXTDS", "PICREP", "fileReference", "text",
    ]

    /// True when the payload holds a note or a reference. It is what keeps a
    /// meta object in the report: M_NPUB carries the chart's cautions, M_QUAL
    /// carries nothing a mariner reads.
    static func carriesInformation(_ json: String) -> Bool {
        attributes(of: json).contains { informational.contains($0.name) && !$0.value.isEmpty }
    }

    /// The report, as plain text for the clipboard: the raw payload, out of
    /// the envelope when there is one — a chart problem is reported with the
    /// cell's own words.
    static func plainText(_ feature: PickFeature) -> String {
        let root = (try? JSONSerialization.jsonObject(with: Data(feature.s57.utf8)))
            as? [String: Any]
        let raw = (root?["report"] != nil ? root?["s57"] : root) as Any?
        var text = "\(feature.cls)  \(feature.chart)\n"
        for row in rows(of: raw) {
            let indent = String(repeating: "  ", count: row.depth)
            text += row.value.isEmpty ? "\(indent)\(row.name):\n"
                                      : "\(indent)\(row.name): \(row.value)\n"
        }
        return text
    }
}
