import GameCore

// The city panel's Builder note (M1 §16): a Builder built where its city's own land has no job
// walks away or waits for a tech, so the Add list and the queue say so before it is built.

extension BuilderGuidance {
    /// The amber note on a Builder in a city's Add list and queue when the city's own land has
    /// no job for it: "No job on Cumae's land", or "No job until Mining" when only an improvement
    /// of a tech not known yet would fit (`builderWork`); nil while it has one.
    static func cityNote(_ view: PlayerView, city: CityID) -> String? {
        guard let work = view.builderWork(in: city), work.jobs == 0 else { return nil }
        guard !work.techs.isEmpty else { return "No job on \(view.city(city)?.name ?? "the city")'s land" }
        return "No job until " + work.techs.map { view.rules.tech($0)?.name ?? $0.rawValue }.joined(separator: " or ")
    }

    /// Whether a production item is a unit that improves tiles (a Builder: it has charges).
    static func isBuilder(_ item: ProductionItem, rules: Ruleset) -> Bool {
        guard case let .unit(type) = item else { return false }
        return rules.unit(type).charges > 0
    }
}
