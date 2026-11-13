// Read-only helpers for the App's tribal village notices (M1 §7.7, §16 "Notifications"; phase 3g
// design §6.2): what a batch of event records the player may see, and what it knew of tribal
// villages before them, tell it about tribal villages. Facts only, from those records and the
// player's own knowledge (its memory, `knownTribalVillages`), never the live sites: the App's
// NoticeMaker turns them into words.

/// Where a tribal village lies, as a notice names it: how far and which way from the player's
/// nearest own city at any distance (ties: the lower id), else from its nearest own unit (ties:
/// the lower id). Unlike the "near Rome" of other notices, it names a place at any distance.
public struct TribalVillagePlace: Hashable, Sendable {
    /// What a place is measured from.
    public enum Anchor: Hashable, Sendable {
        case city(CityID, name: String)
        case unit(UnitID, UnitType)
    }

    public var hex: HexCoord
    /// Nil when the player has neither a city nor a unit.
    public var anchor: Anchor?
    /// Tiles from the anchor (0 without one).
    public var distance: Int
    /// The way from the anchor, as the map shows it (nil on the anchor's own tile, or without
    /// an anchor).
    public var point: CompassPoint?

    public init(hex: HexCoord, anchor: Anchor?, distance: Int, point: CompassPoint?) {
        self.hex = hex
        self.anchor = anchor
        self.distance = distance
        self.point = point
    }

    /// "Rome", "your Settler" (nil without an anchor).
    public var anchorName: String? {
        switch anchor {
        case let .city(_, name)?: name
        case let .unit(_, type)?: "your \(type.displayName)"
        case nil: nil
        }
    }

    /// "5 tiles north-east of Rome", "1 tile west of your Settler"; "at Rome" on the anchor's
    /// own tile; "" without an anchor.
    public var text: String {
        guard let name = anchorName else { return "" }
        guard let point else { return "at \(name)" }
        return "\(distance) tile\(distance == 1 ? "" : "s") \(point.name) of \(name)"
    }

    /// "north-east of Rome", "west of your Settler"; "at Rome" on the anchor's own tile; ""
    /// without an anchor.
    public var direction: String {
        guard let name = anchorName else { return "" }
        guard let point else { return "at \(name)" }
        return "\(point.name) of \(name)"
    }
}

/// What a batch of records, or the start of a game, tells the player about tribal villages
/// (`PlayerView.tribalVillageNews`, `tribalVillageSighting`).
public enum TribalVillageNews: Hashable, Sendable {
    /// Tribal villages the player has come to know, in tile order, with the place of the nearest
    /// (to its anchor; ties: the lower tile).
    case spotted(tiles: [HexCoord], nearest: TribalVillagePlace)
    /// A gift the player had: for a tribal village its unit took (`unit`; `taker` is the unit's
    /// type while it is on the map), or one its city's land took in (`city`, `cityName`).
    /// `byOwnTap`: the player's own command took it (a move it gave, a city it founded), not an
    /// Explore leg, a standing order at its phase start or its borders growing.
    case gift(TribalVillageGift, at: HexCoord, taker: UnitType?, unit: UnitID?, city: CityID?, cityName: String?, byOwnTap: Bool)
    /// Another player took a tribal village the player knew of or sees (with a unit, or its
    /// city's land).
    case reachedFirst(PlayerID, at: HexCoord, place: TribalVillagePlace)
    /// A tribal village the player remembered has left its memory with no event saying who took
    /// it: its tile came back into sight empty.
    case gone(HexCoord, place: TribalVillagePlace)
}

extension PlayerView {
    /// Where the tribal village on `hex` lies for a notice (`TribalVillagePlace`).
    public func tribalVillagePlace(of hex: HexCoord) -> TribalVillagePlace {
        let hex = normalize(hex) ?? hex
        var best: (anchor: TribalVillagePlace.Anchor, from: HexCoord, distance: Int)?
        // Own cities and units come sorted by id: a strict `<` keeps the lower id on a tie.
        for city in cities {
            let d = distance(city.position, hex)
            if d < best?.distance ?? .max { best = (.city(city.id, name: city.name), city.position, d) }
        }
        if best == nil {
            for unit in units {
                let d = distance(unit.position, hex)
                if d < best?.distance ?? .max { best = (.unit(unit.id, unit.type), unit.position, d) }
            }
        }
        guard let best else { return TribalVillagePlace(hex: hex, anchor: nil, distance: 0, point: nil) }
        return TribalVillagePlace(hex: hex, anchor: best.anchor, distance: best.distance,
                                  point: state.map.compassPoint(from: best.from, to: hex))
    }

    /// The tribal villages on `tiles` (tile indices; those off the map are left out) as one
    /// sighting, nil for none: a batch's new ones, or on turn 1 every one the player knows.
    public func tribalVillageSighting(_ tiles: [Int32]) -> TribalVillageNews? {
        var hexes: [HexCoord] = []
        var nearest: TribalVillagePlace?
        for t in tiles.sorted() where (0..<tileCount).contains(Int(t)) {
            let hex = coord(at: Int(t))
            guard !hexes.contains(hex) else { continue }
            hexes.append(hex)
            let place = tribalVillagePlace(of: hex)
            if place.distance < nearest?.distance ?? .max { nearest = place }
        }
        guard let nearest else { return nil }
        return .spotted(tiles: hexes, nearest: nearest)
    }

    /// What `records` (records the player may see, in order) and its knowledge now, against
    /// `knownBefore` (its `knownTribalVillages` just before them), tell it about tribal villages,
    /// in this order:
    /// - for each of its own gifts, in record order, the gift with its take (the latest
    ///   `tribalVillageTaken` of the player on that tile before it); `byOwnTap` when
    ///   `viewerActed` (the records come from the player's own command) and the taker is not a
    ///   unit on the Explore order (`exploring`);
    /// - each other player's take of one the player knew of or sees now (in diagnostic mode the
    ///   App shows every record: a take far from anything the player knows says nothing);
    /// - the tribal villages known now and not before, as one sighting;
    /// - each one known before and no longer, that no take in the records explains: found gone.
    public func tribalVillageNews(in records: [EventRecord], knownBefore before: [Int32], viewerActed: Bool,
                                  exploring: [UnitID] = []) -> [TribalVillageNews] {
        var knownBefore: [Int32] = []
        for t in before.sorted() where knownBefore.last != t { knownBefore.append(t) }
        var news: [TribalVillageNews] = []
        var taken: [Int32] = []
        for (i, record) in records.enumerated() {
            switch record.event {
            case let .tribalVillageTaken(at, taker, _, _):
                guard let t = index(of: at) else { continue }
                SortedTiles.insert(t, into: &taken)
                // The player's own take: its gift says it.
                guard taker != player, SortedTiles.contains(knownBefore, t) || isVisible(index: t) else { continue }
                let hex = coord(at: t)
                news.append(.reachedFirst(taker, at: hex, place: tribalVillagePlace(of: hex)))
            case let .tribalVillageGift(receiver, at, gift) where receiver == player:
                let t = index(of: at)
                var unit: UnitID?, city: CityID?
                for earlier in records[..<i].reversed() {
                    if case let .tribalVillageTaken(hex, taker, u, c) = earlier.event, taker == player, index(of: hex) == t {
                        (unit, city) = (u, c)
                        break
                    }
                }
                let byOwnTap = viewerActed && !(unit.map { exploring.contains($0) } ?? false)
                news.append(.gift(gift, at: t.map { coord(at: $0) } ?? at, taker: unit.flatMap { self.unit($0)?.type }, unit: unit,
                                  city: city, cityName: city.flatMap { self.city($0)?.name }, byOwnTap: byOwnTap))
            default:
                continue
            }
        }
        let now = knownTribalVillages
        if let sighting = tribalVillageSighting(now.filter { !SortedTiles.contains(knownBefore, Int($0)) }) {
            news.append(sighting)
        }
        for t in knownBefore where (0..<tileCount).contains(Int(t)) {
            guard !SortedTiles.contains(now, Int(t)), !SortedTiles.contains(taken, Int(t)) else { continue }
            let hex = coord(at: Int(t))
            news.append(.gone(hex, place: tribalVillagePlace(of: hex)))
        }
        return news
    }
}
