import Foundation
import Testing
@testable import GameCore

/// The standard rules data as a JSON object, to change and load again.
func standardRulesJSON() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Ruleset.standard.data)) as? [String: Any])
}

func loadRules(_ json: [String: Any], options: JSONSerialization.WritingOptions = []) throws -> Ruleset {
    try Ruleset(jsonData: JSONSerialization.data(withJSONObject: json, options: options))
}

/// Changes one field of one entry of a table (`units`, `techs`, …) of rules JSON.
func edit(_ json: inout [String: Any], _ table: String, _ index: Int, _ field: String, _ value: Any) {
    var rows = json[table] as! [[String: Any]]
    rows[index][field] = value
    json[table] = rows
}

/// The validation problems of the standard rules after `change` (empty: they load).
func validationProblems(_ change: (inout [String: Any]) -> Void) throws -> [String] {
    var json = try standardRulesJSON()
    change(&json)
    do {
        _ = try loadRules(json)
        return []
    } catch let error as RulesValidationError {
        return error.problems
    }
}

@Suite struct RulesTests {
    @Test func standardRulesLoadFromTheBundle() {
        let rules = Ruleset.standard
        #expect(rules.id == "m1.1")
        #expect(rules.contentHash != 0)
        #expect(makeTestState().rules == rules)
        #expect(rules.units.map(\.type) == UnitType.allCases)
        #expect(rules.techs.map(\.id) == ["pottery", "mining", "animalHusbandry", "sailing", "writing", "irrigation",
                                          "archery", "bronzeWorking", "masonry", "currency"])
        #expect(rules.civs.map(\.name) == ["Rome", "Mongols", "Mali", "China", "Inca", "Khmer", "Norse", "Abbasid Caliphate"])
        #expect(rules.civs.map(\.leader) == ["Trajan", "Genghis Khan", "Mansa Musa", "Wu Zetian", "Pachacuti",
                                             "Jayavarman VII", "Harald Hardrada", "Harun al-Rashid"])
        #expect(rules.civs.allSatisfy { $0.cityNames.count >= 12 })
    }

    /// The numbers of M1 §4–§7 and §10, as the data holds them.
    @Test func rulesMatchTheM1Tables() throws {
        let rules = Ruleset.standard
        func unit(_ t: UnitType) -> UnitDef { rules.unit(t) }
        #expect(UnitType.allCases.map { unit($0).cost } == [60, 40, 30, 40, 60, 65])
        #expect(UnitType.allCases.map { unit($0).strength } == [0, 0, 10, 20, 15, 25])
        #expect(UnitType.allCases.map { unit($0).moves } == [2, 2, 3, 2, 2, 2])
        #expect(UnitType.allCases.map { unit($0).sight } == [2, 2, 3, 2, 2, 2])
        #expect(UnitType.allCases.map { unit($0).unitClass } == [.civilian, .civilian, .recon, .melee, .ranged, .antiCavalry])
        #expect(unit(.archer).rangedStrength == 25 && unit(.archer).range == 2 && unit(.archer).tech == "archery")
        #expect(unit(.spearman).tech == "bronzeWorking" && unit(.spearman).classBonuses == [ClassBonus(against: .cavalry, strength: 10)])
        #expect(unit(.builder).charges == 3)
        #expect(unit(.settler).foundsCity && unit(.settler).minPopulation == 2 && unit(.settler).populationCost == 1)
        for type in UnitType.allCases { #expect(unit(type).isMilitary == !type.isCivilian) }

        let buildings = ["monument", "granary", "library", "walls", "market"].map { rules.building(BuildingID($0))! }
        #expect(buildings.map(\.cost) == [30, 55, 70, 60, 80])
        #expect(buildings.map(\.tech) == [nil, "pottery", "writing", "masonry", "currency"])
        #expect(buildings.map(\.yields) == [Yields(culture: 2), Yields(food: 2), Yields(science: 3), .zero, Yields(gold: 3)])
        #expect(buildings[3].wallHP == 100 && buildings[3].cityStrength == 5)
        #expect(rules.palace.yields == Yields(production: 2, gold: 3, science: 3, culture: 1) && !rules.palace.buildable)

        #expect(rules.techs.map(\.cost) == [25, 25, 25, 40, 45, 45, 45, 45, 45, 70])
        #expect(rules.techs.map(\.requires) == [[], [], [], ["pottery"], ["pottery"], ["pottery"], ["animalHusbandry"],
                                                ["mining"], ["mining"], ["writing"]])

        #expect((1...6).map { rules.growthThreshold(population: $0) } == [11, 20, 29, 40, 51, 62]) // p3f: base 11
        #expect((0...2).map { rules.borderThreshold(tilesGained: $0) } == [10, 16, 22])
        let c = rules.constants
        #expect(c.start.gold == 10 && c.start.units == [.settler, .warrior, .scout])
        #expect(c.production.maxQueue == 6 && c.production.purchaseCostMultiplier == 3 && c.production.storedProgressCapMultiplier == 2)
        #expect(c.production.waitingHeadFillPct == 100 && c.city.foundingProduction == 40) // p3f, p3d
        #expect(c.city.youngCityProduction == 0 && c.city.capturedProduction == 0) // p3f experiments, off
        #expect(c.city.minDistance == 4 && c.city.workRadius == 3 && c.city.sight == 2 && c.city.maxHP == 200)
        #expect(c.upkeep.freeBase == 2 && c.upkeep.freePerCity == 1 && c.upkeep.goldPerUnit == 1)
        let healing: [Int] = [c.healing.ownCity, c.healing.ownTerritory, c.healing.neutral, c.healing.foreign]
        #expect(healing == [20, 15, 10, 5])
        #expect(c.knowledge.sightingMaxAge == 20 && c.turnLimit == 250)
        #expect(rules.focuses.map(\.foodFloor) == [2, 2, 0, 0])
        #expect(rules.aiMaxCities(mapSize: "duel") == 6 && rules.aiMaxCities(mapSize: "large") == 12)
    }

    @Test func integerSquareRoot() {
        #expect((0...17).map(isqrt) == [0, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 4, 4])
        for n in [99, 100, 101, 999_999, 1_000_000, 2_147_483_647, 1 << 52] {
            let r = isqrt(n)
            #expect(r * r <= n && (r + 1) * (r + 1) > n, "isqrt(\(n)) = \(r)")
        }
    }

    /// The content hash fingerprints the decoded data, not the file's bytes.
    @Test func contentHashIgnoresFormatting() throws {
        let json = try standardRulesJSON()
        let compact = try loadRules(json)
        let pretty = try loadRules(json, options: [.prettyPrinted, .sortedKeys])
        #expect(compact == pretty && compact.contentHash == pretty.contentHash)
        #expect(compact == Ruleset.standard)

        var changed = json
        edit(&changed, "units", 3, "cost", 41)
        let other = try loadRules(changed)
        #expect(other.id == compact.id && other.contentHash != compact.contentHash)
        #expect(other != compact)
    }

    /// A state refers to its rules by identity: it decodes against the ruleset in the decoder's
    /// `userInfo` (by default the standard one) and refuses rules with another id.
    @Test func stateDecodesAgainstItsRules() throws {
        let state = makeTestState()
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(GameState.self, from: data) == state)

        var json = try standardRulesJSON()
        json["id"] = "test.9"
        let decoder = JSONDecoder()
        decoder.userInfo[.ruleset] = try loadRules(json)
        #expect(throws: RulesMismatch(saved: "m1.1", current: "test.9")) {
            try decoder.decode(GameState.self, from: data)
        }
    }

    /// Validation on load (M1 §12.2): every enum case has exactly one def, no dangling
    /// references, an acyclic tech graph, numbers in range, `isCivilian` matches the class.
    @Test func validationRejectsBrokenData() throws {
        func expectProblem(_ fragment: String, _ change: (inout [String: Any]) -> Void,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
            let problems = try validationProblems(change)
            #expect(problems.contains { $0.contains(fragment) }, "\(problems)", sourceLocation: sourceLocation)
        }
        #expect(try validationProblems { _ in }.isEmpty)
        try expectProblem("spearman has 0 definitions") { json in
            json["units"] = (json["units"] as! [[String: Any]]).filter { $0["type"] as? String != "spearman" }
        }
        try expectProblem("forest has 2 definitions") { json in
            json["features"] = (json["features"] as! [[String: Any]]) + [(json["features"] as! [[String: Any]])[1]]
        }
        try expectProblem("does not match UnitType.isCivilian") { edit(&$0, "units", 0, "class", "melee") }
        try expectProblem("unknown prerequisite") { edit(&$0, "techs", 3, "requires", ["fire"]) }
        try expectProblem("cycle") { edit(&$0, "techs", 0, "requires", ["currency"]) }
        try expectProblem("must come earlier") { edit(&$0, "techs", 0, "requires", ["currency"]) }
        try expectProblem("unknown tech") { edit(&$0, "buildings", 2, "tech", "alchemy") }
        try expectProblem("cost must be positive") { edit(&$0, "units", 3, "cost", 0) }
        try expectProblem("at least 12 city names") { json in
            var civs = json["civs"] as! [[String: Any]]
            civs[1]["cityNames"] = Array((civs[1]["cityNames"] as! [String]).prefix(11))
            json["civs"] = civs
        }
        try expectProblem("unknown terrain") { json in
            var improvements = json["improvements"] as! [[String: Any]]
            var sites = improvements[0]["sites"] as! [[String: Any]]
            sites[0]["terrains"] = ["swamp"]
            improvements[0]["sites"] = sites
            json["improvements"] = improvements
        }
        try expectProblem("researchOrderPeace must list every tech once") { json in
            var ai = json["ai"] as! [String: Any]
            ai["researchOrderPeace"] = Array((ai["researchOrderPeace"] as! [String]).dropLast())
            json["ai"] = ai
        }
        try expectProblem("exactly one palace") { edit(&$0, "buildings", 1, "palace", true) }
    }
}

@Suite struct IdentifierTests {
    /// Rules-data IDs are plain JSON strings, ordered by their text.
    @Test func stringIDsEncodeAsPlainStrings() throws {
        let encoded = try JSONEncoder().encode([TechID("pottery")])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["pottery"]"#)
        #expect(try JSONDecoder().decode([BuildingID].self, from: Data(#"["library"]"#.utf8)) == ["library"])
        #expect(TechID("mining") < TechID("pottery") && CivID("mali") < CivID("rome"))
        let item = ProductionItem.building("granary")
        #expect(try JSONDecoder().decode(ProductionItem.self, from: JSONEncoder().encode(item)) == item)
    }

    @Test func eventAudiences() throws {
        let event = GameEvent.playersMet(PlayerID(0), PlayerID(2))
        let both = EventRecord(event, audience: 0b101)
        #expect(both.isVisible(to: PlayerID(0)) && both.isVisible(to: PlayerID(2)))
        #expect(!both.isVisible(to: PlayerID(1)))
        #expect(EventRecord(event, audience: EventRecord.everyone).isVisible(to: PlayerID(7)))
        #expect(try JSONDecoder().decode(EventRecord.self, from: JSONEncoder().encode(both)) == both)
    }
}
