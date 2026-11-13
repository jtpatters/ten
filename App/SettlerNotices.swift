import GameCore

// A Settler's march ending where it can found a city (M1 §16 Notifications). A standing march
// goes on at the start of its owner's phase, out of the viewer's sight, often with no moves
// left at its goal; founding takes none, so the line says the city can be founded now. The
// Settler also stays in the attention queue (`PlayerView.standsReadyToFound`).

extension NoticeMaker {
    /// "Settler reached its site: it can found the city now", for each own unit that founds
    /// cities whose march ended on its goal in these events (another player's command: the
    /// viewer's phase start), where it can found a city.
    static func settlerArrivals(in records: [EventRecord], view: PlayerView, before: UnitsBefore) -> [Notice] {
        var moved: [UnitID] = []
        for record in records {
            if case let .unitMoved(unit, _, _) = record.event, !moved.contains(unit) { moved.append(unit) }
        }
        var out: [Notice] = []
        for id in moved {
            guard let unit = view.unit(id), unit.owner == view.player, let goal = before[id]?.destination,
                  unit.position == goal, view.standsReadyToFound(unit) else { continue }
            out.append(Notice(kind: .settlerArrived, text: "\(unit.type.displayName) reached its site: it can found the city now",
                              systemImage: "flag.checkered", tone: .good, importance: .info, place: unit.position,
                              subject: .unit(id), turn: view.turn))
        }
        return out
    }
}
