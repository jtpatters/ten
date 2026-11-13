import GameCore
import MapRendering

/// Builder guidance (M1 §16): how many sites near the player's cities a tech's improvement has,
/// for the tech panel, and the tiles a selected Builder could work, for the map. Both come from
/// the player's knowledge (`improvementSites`, `builderJobs`); no rule changes.
enum BuilderGuidance {
    /// The tech panel's options, each improvement they unlock described by its sites near the
    /// player's cities ("Pasture: 2 on your land, 13 more as borders grow"; once the tech is
    /// known, "Mine: 3 jobs now"); unchanged while the player has no city.
    static func annotated(_ options: [ResearchOption], _ view: PlayerView) -> [ResearchOption] {
        guard !view.cities.isEmpty else { return options }
        return options.map { option in
            var option = option
            for sites in view.improvementSites(unlockedBy: option.tech) {
                let name = view.rules.improvement(sites.improvement).displayName
                let line = text(sites, name: name, known: option.known)
                if let i = option.unlocks.firstIndex(of: name) { option.unlocks[i] = line } else { option.unlocks.append(line) }
            }
            return option
        }
    }

    /// Before the tech: "Pasture: 2 on your land, 13 more as borders grow", "Pasture: 2 on your
    /// land", "Pasture: none on your land yet (13 as borders grow)", "Mine: no hills near your
    /// cities". Once it is known, only the work on own land: "Mine: 3 jobs now", "Mine: no jobs
    /// now".
    static func text(_ sites: ImprovementSites, name: String, known: Bool = false) -> String {
        let own = sites.ownLand, more = sites.unclaimed
        if known { return "\(name): " + (own == 0 ? "no jobs now" : own == 1 ? "1 job now" : "\(own) jobs now") }
        if own == 0 {
            return more == 0 ? "\(name): no \(sites.onHillsOnly ? "hills" : "sites") near your cities"
                : "\(name): none on your land yet (\(more) as borders grow)"
        }
        return "\(name): \(own) on your land" + (more == 0 ? "" : ", \(more) more as borders grow")
    }
}

extension MapAdapter {
    /// The Builder's job marks: the tiles a selected own Builder could work (`builderJobs`),
    /// each with what it could build there, a solid ring where it could start this phase and a
    /// dashed one where it needs more turns; empty when it has none (or is no Builder).
    static func builderJobMarks(_ view: PlayerView, for id: UnitID) -> [JobMark] {
        view.builderJobs(for: id).map { JobMark(hex: $0.hex, improvements: $0.improvements, thisPhase: $0.thisPhase) }
    }
}
