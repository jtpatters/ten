// A Settler ready to found (M1 §16): founding takes no moves (the engine's foundCity checks only
// the unit and the site), so a Settler standing on a site it may found still has something to
// do. The attention queue keeps it whatever its moves, and a march ending on such a site at the
// phase start gets a notice.

extension PlayerView {
    /// Whether `unit` is an own unit that founds cities, with no orders and no activity, standing
    /// where this player could found a city now (`canFoundCity`): Next stops for it even with no
    /// moves left.
    public func standsReadyToFound(_ unit: Unit) -> Bool {
        unit.owner == player && rules.unit(unit.type).foundsCity && unit.destination == nil && unit.activity == .none
            && canFoundCity(at: unit.position)
    }
}
