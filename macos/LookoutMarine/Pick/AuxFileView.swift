//  AuxFileView.swift — a file a picked feature points at.
//
//  A cell can name a text file or a picture beside it: the text of a caution
//  note, or the diagram itself. The engine reads it out of the chart; this
//  shows it, and a click opens a picture at full size.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif


/// A file a feature points at, read through the engine and shown here: the text
/// of a caution note, or the picture itself. The bake stores those files beside
/// the chart; a chart baked before that carries the name alone.
struct AuxFileView: View {
    var model: AppModel
    let cell: String
    let name: String
    let isPicture: Bool

    @State private var loaded: (data: Data, mime: String)?
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isPicture ? "photo" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.accent)
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
            }
            content
        }
        .onAppear(perform: load)
        .onChange(of: name) { tried = false; loaded = nil; load() }
    }

    @ViewBuilder private var content: some View {
        if let loaded {
            if let image = Self.image(from: loaded) {
                Button {
                    model.picture = .init(name: name, data: loaded.data)
                } label: {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // A chart picture is a diagram or a note: 200pt made it
                        // unreadable. Click it for the full size.
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Chrome.edge.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Show \(name) at full size")
                .accessibilityLabel("Show \(name) at full size")
            } else if let text = String(data: loaded.data, encoding: .utf8)
                        ?? String(data: loaded.data, encoding: .isoLatin1) {
                // No scroll view here: the report itself scrolls. A note inside
                // its own little scroller fights the one around it, and a
                // caution is worth reading in full.
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Chrome.ink.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        } else if tried {
            Text("The chart does not carry this file.")
                .font(.system(size: 10))
                .foregroundStyle(Chrome.muted)
        }
    }

    private func load() {
        guard !tried else { return }
        tried = true
        loaded = model.controller?.auxFile(cell: cell, named: name)
    }

    /// A picture, whatever the format the cell shipped: the platform decodes
    /// TIFF, which is what an ENC usually carries.
    static func image(from file: (data: Data, mime: String)) -> Image? {
        guard file.mime.hasPrefix("image/") else { return nil }
        #if os(macOS)
        guard let ns = NSImage(data: file.data) else { return nil }
        return Image(nsImage: ns)
        #else
        guard let ui = UIImage(data: file.data) else { return nil }
        return Image(uiImage: ui)
        #endif
    }
}



/// A picture from a pick report, over the chart at full size. A click anywhere,
/// or Escape, puts it away.
struct PictureViewer: View {
    var model: AppModel
    let picture: AppModel.Picture

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 10) {
                if let image = AuxFileView.image(from: (picture.data, "image/")) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                }
                Text(picture.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.picture = nil }
        #if os(macOS)
        .onExitCommand { model.picture = nil }
        #endif
    }
}
