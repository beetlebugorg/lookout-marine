//
//  The volume the sheet lies in, and the hands that reach into it.
//
//  Each gesture is aimed at one part of the sheet, so the margin and the face
//  never argue over a hand: a gesture targeted at the face never fires for the
//  margin, and the other way round.
//

import RealityKit
import SwiftUI

struct ChartTableView: View {
    @State private var model = TableModel()
    @State private var choosingCharts = false

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                model.open()
                content.add(model.sheet.root)
                lay(model.sheet.root, in: proxy, content: content)
                // One tick per rendered frame. The chart only records a frame
                // when it owes one, so a still chart costs a redraw check.
                _ = content.subscribe(to: SceneEvents.Update.self) { event in
                    model.tick(event.deltaTime, now: Date.timeIntervalSinceReferenceDate)
                }
            } update: { content in
                lay(model.sheet.root, in: proxy, content: content)
            }
            .gesture(chartDrag)
            .simultaneousGesture(chartZoom)
            .simultaneousGesture(chartRotate)
            .simultaneousGesture(chartTap)
            .simultaneousGesture(sheetDrag)
            .simultaneousGesture(sheetResize)
            .simultaneousGesture(sheetRotate)
            .overlay(alignment: .center) {
                // With no chart there is nothing on the table and nothing to
                // do but find one, so the app asks for it outright rather than
                // leaving a row of controls that answer to nothing.
                if !model.ready {
                    VStack(spacing: 16) {
                        Text("Lookout Table")
                            .font(.title)
                        Text(model.status)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button("Choose Charts") { choosingCharts = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                    .glassBackgroundEffect()
                }
            }
        }
        // The front face, not the bottom: a volume's bottom is the floor the
        // sheet lies on, so an ornament anchored there sits inside the table.
        .ornament(attachmentAnchor: .scene(.front)) {
            ChartTableControls(model: model, choosingCharts: $choosingCharts)
        }
        // A chart the system hands over: a .pmtiles AirDropped or opened from
        // Files, or a folder of them. It is adopted the same way the picker's
        // answer is.
        .onOpenURL { url in
            model.openPicked(url)
        }
        // A folder of cells or a single .pmtiles. The folder is walked, and
        // whichever is chosen is remembered for the next launch.
        .fileImporter(
            isPresented: $choosingCharts,
            allowedContentTypes: [.folder, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.openPicked(url) }
            case .failure(let error):
                model.status = "That folder could not be opened."
                lkLog("chart picker: \(error)")
            }
        }
    }

    /// Lay the sheet flat on the floor of the volume, where a chart on a table
    /// sits, and tell the model how much room it has. The volume can be
    /// resized, so this runs on every update.
    private func lay(_ root: Entity, in proxy: GeometryProxy3D, content: RealityViewContent) {
        let box = content.convert(proxy.frame(in: .local), from: .local, to: .scene)
        root.position = [0, box.min.y + 0.01, 0]
        model.setVolumeWidth(box.extents.x)
    }

    // MARK: - A hand on the chart

    private var chartDrag: some Gesture {
        DragGesture()
            .targetedToEntity(where: .has(ChartFaceTag.self))
            .onChanged { v in
                model.chartDragChanged(
                    to: v.convert(v.location3D, from: .local, to: model.sheet.root),
                    at: v.gestureValue.time.timeIntervalSinceReferenceDate)
            }
            .onEnded { _ in model.chartDragEnded() }
    }

    private var chartZoom: some Gesture {
        MagnifyGesture()
            .targetedToEntity(where: .has(ChartFaceTag.self))
            .onChanged { v in
                let anchor = v.convert(v.startLocation3D, from: .local, to: model.sheet.root)
                model.chartZoomChanged(v.magnification, anchor: anchor)
            }
            .onEnded { _ in model.chartZoomEnded() }
    }

    private var chartRotate: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToEntity(where: .has(ChartFaceTag.self))
            .onChanged { v in
                model.chartRotateChanged(signedYaw(v.rotation))
            }
            .onEnded { _ in model.chartRotateEnded() }
    }

    private var chartTap: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(where: .has(ChartFaceTag.self))
            .onEnded { v in
                model.tapChart(at: v.convert(v.location3D, from: .local, to: model.sheet.root))
            }
    }

    // MARK: - A hand on the margin

    private var sheetDrag: some Gesture {
        DragGesture()
            .targetedToEntity(where: .has(SheetBorderTag.self))
            .onChanged { v in
                model.sheetDragChanged(to: v.convert(v.location3D, from: .local, to: .scene))
            }
            .onEnded { _ in model.sheetDragEnded() }
    }

    private var sheetResize: some Gesture {
        MagnifyGesture()
            .targetedToEntity(where: .has(SheetBorderTag.self))
            .onChanged { v in model.sheetResizeChanged(v.magnification) }
            .onEnded { _ in model.sheetResizeEnded() }
    }

    private var sheetRotate: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToEntity(where: .has(SheetBorderTag.self))
            .onChanged { v in model.sheetRotateChanged(signedYaw(v.rotation)) }
            .onEnded { _ in model.sheetRotateEnded() }
    }

    /// The turn about the up axis, in radians, with the sign the hands made.
    /// A rotation about -Y is the same angle the other way round.
    private func signedYaw(_ r: Rotation3D) -> Double {
        let axis = r.axis
        return r.angle.radians * (axis.y < 0 ? -1 : 1)
    }
}

/// The few controls a chart table needs. Everything else is done with hands.
private struct ChartTableControls: View {
    let model: TableModel
    @Binding var choosingCharts: Bool

    var body: some View {
        HStack(spacing: 18) {
            Button {
                choosingCharts = true
            } label: {
                Label("Charts", systemImage: "folder")
            }
            Button {
                model.cycleScheme()
            } label: {
                Label("Day, dusk, night", systemImage: "circle.lefthalf.filled")
            }
            .disabled(!model.ready)
            Button {
                model.fitChart()
            } label: {
                Label("Whole chart", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!model.ready)
            Button {
                model.followOwnShip()
            } label: {
                Label("Own ship", systemImage: "location.fill")
            }
            .disabled(!model.ready)
            Button {
                model.levelSheet()
            } label: {
                Label("Square the sheet", systemImage: "square.grid.2x2")
            }
            .disabled(!model.ready)
        }
        .labelStyle(.iconOnly)
        .padding(12)
        .glassBackgroundEffect()
    }
}
