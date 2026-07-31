// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// The chrome's icons, drawn as strokes rather than set in a font.
//
// The Apple shell names SF Symbols ("plus", "xmark", "chevron.left"). There is
// no such set on the tablet, and a font-based icon set would be one more thing
// to ship and to hint at 226 ppi. These are the same shapes drawn on a Canvas:
// vector, so they stay crisp, and pure black, so the panel never dithers them.
//
// `name` uses the SF Symbol names the Apple shell asks for, so the two shells'
// chrome reads the same in source.
Canvas {
    id: root

    property string name: ""
    property color color: Theme.ink
    property real weight: 2.0 // stroke width at the base size, scaled with it

    implicitWidth: Math.round(18 * Theme.ui)
    implicitHeight: implicitWidth
    antialiasing: false // e-ink: a hard edge beats a grey fringe

    onNameChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.reset()
        const w = width, h = height
        const s = Math.min(w, h)
        ctx.strokeStyle = root.color
        ctx.fillStyle = root.color
        ctx.lineWidth = Math.max(1, Math.round(root.weight * s / 18))
        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        const cx = w / 2, cy = h / 2
        const r = s * 0.30 // the half-extent most glyphs are drawn within

        function line(x1, y1, x2, y2) {
            ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke()
        }

        switch (root.name) {
        case "plus":
            line(cx - r, cy, cx + r, cy); line(cx, cy - r, cx, cy + r); break
        case "minus":
            line(cx - r, cy, cx + r, cy); break
        case "xmark":
            line(cx - r, cy - r, cx + r, cy + r); line(cx + r, cy - r, cx - r, cy + r); break
        case "chevron.left":
            line(cx + r * 0.5, cy - r, cx - r * 0.5, cy); line(cx - r * 0.5, cy, cx + r * 0.5, cy + r); break
        case "chevron.right":
            line(cx - r * 0.5, cy - r, cx + r * 0.5, cy); line(cx + r * 0.5, cy, cx - r * 0.5, cy + r); break
        case "chevron.up":
            line(cx - r, cy + r * 0.5, cx, cy - r * 0.5); line(cx, cy - r * 0.5, cx + r, cy + r * 0.5); break
        case "chevron.down":
            line(cx - r, cy - r * 0.5, cx, cy + r * 0.5); line(cx, cy + r * 0.5, cx + r, cy - r * 0.5); break
        case "slider.horizontal.3": // settings
            for (let i = -1; i <= 1; ++i) {
                const y = cy + i * r * 0.8
                line(cx - r, y, cx + r, y)
                ctx.beginPath()
                ctx.arc(cx + i * r * 0.45, y, ctx.lineWidth * 1.4, 0, Math.PI * 2)
                ctx.fill()
            }
            break
        case "map": // open a chart
            ctx.beginPath()
            ctx.moveTo(cx - r, cy - r * 0.75); ctx.lineTo(cx - r * 0.33, cy - r)
            ctx.lineTo(cx + r * 0.33, cy - r * 0.75); ctx.lineTo(cx + r, cy - r)
            ctx.lineTo(cx + r, cy + r * 0.75); ctx.lineTo(cx + r * 0.33, cy + r)
            ctx.lineTo(cx - r * 0.33, cy + r * 0.75); ctx.lineTo(cx - r, cy + r)
            ctx.closePath(); ctx.stroke()
            line(cx - r * 0.33, cy - r, cx - r * 0.33, cy + r * 0.75)
            line(cx + r * 0.33, cy - r * 0.75, cx + r * 0.33, cy + r)
            break
        case "square.grid.3x3": // the cell a feature came from
            for (let gx = -1; gx <= 1; ++gx)
                for (let gy = -1; gy <= 1; ++gy) {
                    ctx.beginPath()
                    ctx.rect(cx + gx * r * 0.7 - r * 0.22, cy + gy * r * 0.7 - r * 0.22,
                             r * 0.44, r * 0.44)
                    ctx.fill()
                }
            break
        case "square.on.square": // copy
            ctx.beginPath(); ctx.rect(cx - r, cy - r * 0.55, r * 1.55, r * 1.55); ctx.stroke()
            ctx.beginPath(); ctx.rect(cx - r * 0.55, cy - r, r * 1.55, r * 1.55); ctx.stroke()
            break
        case "doc.text": // a text note the cell points at
            ctx.beginPath(); ctx.rect(cx - r * 0.75, cy - r, r * 1.5, r * 2); ctx.stroke()
            for (let i = -1; i <= 1; ++i)
                line(cx - r * 0.4, cy + i * r * 0.45, cx + r * 0.4, cy + i * r * 0.45)
            break
        case "photo": // a diagram the cell points at
            ctx.beginPath(); ctx.rect(cx - r, cy - r * 0.8, r * 2, r * 1.6); ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(cx - r * 0.8, cy + r * 0.6); ctx.lineTo(cx - r * 0.1, cy - r * 0.2)
            ctx.lineTo(cx + r * 0.35, cy + r * 0.25); ctx.lineTo(cx + r * 0.6, cy)
            ctx.lineTo(cx + r * 0.85, cy + r * 0.6)
            ctx.stroke()
            break
        case "arrow.up.left.and.arrow.down.right": // fit the chart
            line(cx - r, cy - r, cx - r * 0.15, cy - r * 0.15)
            line(cx - r, cy - r, cx - r, cy - r * 0.35); line(cx - r, cy - r, cx - r * 0.35, cy - r)
            line(cx + r, cy + r, cx + r * 0.15, cy + r * 0.15)
            line(cx + r, cy + r, cx + r, cy + r * 0.35); line(cx + r, cy + r, cx + r * 0.35, cy + r)
            break
        case "magnifyingglass":
            ctx.beginPath(); ctx.arc(cx - r * 0.2, cy - r * 0.2, r * 0.65, 0, Math.PI * 2); ctx.stroke()
            line(cx + r * 0.28, cy + r * 0.28, cx + r * 0.85, cy + r * 0.85)
            break
        }
    }
}
