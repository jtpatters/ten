// What a city's own land offers its Builders (M1 §16 city panel): a Builder built where its
// city's land has no job walks away or waits for a tech, so the Add list and the queue say so.

/// The jobs on a city's land (M1 §7.2): its tiles where a Builder could build now, by the
/// player's knowledge, else the techs that would give one.
public struct CityBuilderWork: Hashable, Sendable {
    /// The city's tiles (explored, no improvement as last seen, not its centre) where an
    /// improvement whose tech is known could go.
    public var jobs: Int
    /// With no job: the techs not known, in rules order, whose improvements would fit a tile of
    /// its land.
    public var techs: [TechID]
}

extension PlayerView {
    /// The jobs on an own city's land (`CityBuilderWork`); nil for a city not this player's.
    public func builderWork(in id: CityID) -> CityBuilderWork? {
        guard let city = state.city(id), city.owner == player else { return nil }
        let code = Int32(id.rawValue + 1)
        let kinds = Improvement.allCases
        let known = kinds.map { rules.improvement($0).tech.map(me.knows) ?? true }
        var fits = [Bool](repeating: false, count: kinds.count)
        var jobs = 0
        for t in 0..<tileCount where state.tileCity[t] == code {
            guard me.explored[t], me.memory.tileImprovement[t] == 0, state.city(atTile: t) == nil else { continue }
            let tile = state.map.tiles[t]
            var job = false
            for k in kinds.indices where rules.allowsImprovement(kinds[k], on: tile) {
                fits[k] = true
                if known[k] { job = true }
            }
            if job { jobs += 1 }
        }
        var techs: [TechID] = []
        if jobs == 0 {
            for k in kinds.indices where fits[k] {
                if let tech = rules.improvement(kinds[k]).tech, !techs.contains(tech) { techs.append(tech) }
            }
        }
        return CityBuilderWork(jobs: jobs, techs: techs)
    }
}
