import GameCore
@testable import MapRendering

/// What the App passes the renderer for the selected unit's guidance and the ready units, on
/// this engine: the settler overlay's scores and the Builder's job marks
/// (`GameSession.refreshSelection`, `MapAdapter.builderJobMarks`), and the Settlers that may
/// found a city where they stand (`MapAdapter.readyUnits`). The base engine's A/B copy swaps in
/// a version of this file that passes what the App passed then.
@MainActor
enum GuidanceOverlay {
    static let engine = "new"

    static func apply(_ scene: GuidanceFixture.Scene, to renderer: MapRenderer) {
        renderer.setTileScores(scene.siteScores, jobs: scene.jobs.map { JobMark(hex: $0.hex, improvements: $0.improvements, thisPhase: $0.thisPhase) })
        renderer.setReadyUnits(scene.ready)
    }
}
