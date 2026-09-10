//  FirstRunParts.swift: the pieces every setup step is built from.
//
//  A step is a heading, some rows or cards, and at most one warning. Sizes come
//  from the design board. Colors come from Chrome, the palette the chart chrome
//  and the Windows shell share.

import SwiftUI

/// A step's heading: what it asks, and the sentence under it.
struct StepHeading: View {
    let title: String
    let blurb: String
    /// Centered in a sheet, ranged left on a phone screen. A full-width column
    /// of cards gives a centered heading no shorter line to center against.
    var centered = true

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 9) {
            Text(title)
                .font(.system(size: centered ? 24 : 22, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(Chrome.ink)
            Text(blurb)
                .font(.system(size: 13.5))
                .lineSpacing(1.5)
                .foregroundStyle(Chrome.muted)
                .frame(maxWidth: centered ? 470 : nil, alignment: centered ? .center : .leading)
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

/// One fact on the welcome page: an icon, a claim, and what it means.
struct StepFact: View {
    let icon: String
    let title: String
    let blurb: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Chrome.accent)
                .frame(width: 30, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Text(blurb)
                    .font(.system(size: 13))
                    .lineSpacing(1.5)
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A pick-one card: the icon, the name, the description, and the mark for the
/// chosen one.
///
/// A Button rather than a tap gesture on a shape. A shape with a tap gesture is
/// invisible to the keyboard and to VoiceOver, and this control sets what the
/// rest of setup asks.
struct SourceCard: View {
    let icon: String
    let title: String
    /// Set on the card the app preselects.
    var recommended = false
    let blurb: String
    let picked: Bool
    /// Stacked on a phone, side by side in a sheet. A row of cards reaches a
    /// common height, so the mark goes at the bottom rather than beside the
    /// title.
    var stacked = false
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            if stacked { rowBody } else { columnBody }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("source-\(title)")
    }

    private var columnBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            iconTile(size: 56, glyph: 24, radius: 14)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .padding(.top, 16)
            if recommended {
                Text("Recommended")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Chrome.accent)
                    .padding(.top, 3)
            }
            Text(blurb)
                .font(.system(size: 12.5))
                .lineSpacing(1.5)
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
            mark.padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 21)
        .padding(.horizontal, 17)
        .modifier(CardSkin(picked: picked, radius: 12))
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 14) {
            iconTile(size: 44, glyph: 20, radius: 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                    if recommended {
                        Text("Recommended")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Chrome.accent)
                    }
                }
                Text(blurb)
                    .font(.system(size: 13))
                    .lineSpacing(1.5)
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            mark.padding(.top, 2)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .modifier(CardSkin(picked: picked, radius: 14))
    }

    private func iconTile(size: CGFloat, glyph: CGFloat, radius: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: glyph, weight: .regular))
            .foregroundStyle(Chrome.accent)
            .frame(width: size, height: size)
            .background(Chrome.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var mark: some View {
        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(picked ? Chrome.accent : Chrome.ink.opacity(0.30))
    }
}

/// The chosen card's 2pt accent border and tinted fill, or the plain one.
struct CardSkin: ViewModifier {
    let picked: Bool
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(picked ? Chrome.accent.opacity(0.05) : Chrome.surface, in: shape)
            .overlay(shape.strokeBorder(picked ? Chrome.accent : Chrome.edge.opacity(0.7),
                                        lineWidth: picked ? 2 : 1))
            .contentShape(shape)
    }
}

/// The publisher's warning, in the publisher's terms. Amber, and shaped
/// differently from an ordinary note, so it separates from the page at a
/// glance.
struct StepWarning: View {
    let lead: String
    let body_: String
    var link: (title: String, url: URL)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.amber)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    Text(lead).fontWeight(.semibold).foregroundStyle(Chrome.ink)
                    + Text(" ") + Text(body_).foregroundStyle(Chrome.muted)
                }
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                if let link {
                    Link(link.title, destination: link.url)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Chrome.accent)
                }
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(Chrome.amber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A labeled control in a step's settings block: the label ranged right in a
/// fixed gutter, the control, and its effect on the chart beside it.
struct StepControlRow<Control: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        #if os(macOS)
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Chrome.muted)
                .frame(width: 150, alignment: .trailing)
            control
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Chrome.muted)
                control
            }
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }
}
