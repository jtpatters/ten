#if DEBUG
import Foundation
import GameCore
import MapGen
import MapRendering
import Persistence
import UIKit

/// Drives a debug build from a file, for agents and scripts that cannot touch the simulator
/// (App/AUTOMATION.md). Every 0.25 s the app looks for `Documents/automation.txt`; it takes the
/// file, runs its lines in order (waiting where a command waits), then writes
/// `Documents/automation.done` with one `ok …` or `error …` line per command.
@MainActor
final class AutomationInbox {
    static let inbox = URL.documentsDirectory.appending(path: "automation.txt")
    static let done = URL.documentsDirectory.appending(path: "automation.done")
    static let stateFile = URL.documentsDirectory.appending(path: "automation-state.json")

    private weak var model: AppModel?
    private var task: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.poll()
            }
        }
    }

    private func poll() async {
        let files = FileManager.default
        guard files.fileExists(atPath: Self.inbox.path), let text = try? String(contentsOf: Self.inbox, encoding: .utf8) else { return }
        try? files.removeItem(at: Self.inbox)
        try? files.removeItem(at: Self.done)
        var log: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let command = line.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty, !command.hasPrefix("#") else { continue }
            do {
                let result = try await run(command)
                log.append("ok \(command)" + (result.isEmpty ? "" : " -> \(result)"))
            } catch {
                log.append("error \(command) -> \(error)")
            }
        }
        try? (log.joined(separator: "\n") + "\n").write(to: Self.done, atomically: true, encoding: .utf8)
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    // MARK: Commands

    /// Runs one command line; returns a short result for the log.
    func run(_ line: String) async throws -> String {
        let words = line.split(separator: " ").map(String.init)
        guard let model, let verb = words.first?.lowercased() else { throw Failure(description: "no app") }
        let args = Array(words.dropFirst())

        switch verb {
        case "newgame":
            // newgame [size] [seed] [civ] [fog|nofog] [pangaea|continents|archipelago]
            let size = args.first.flatMap(MapSize.init(rawValue:)) ?? .duel
            let seed = args.count > 1 ? UInt64(args[1]) ?? 42 : 42
            let civ = args.count > 2 ? CivID(args[2]) : AppModel.defaultCiv
            let diagnostic = args.contains("nofog")
            let script = args.lazy.compactMap(MapScript.init(rawValue:)).first ?? .pangaea
            await model.startNewGame(AppModel.NewGameSetup(size: size, seed: seed, civ: civ, diagnostic: diagnostic, script: script))
            try await waitIdle(model)
            return describe(model.session)
        case "scenario":
            guard let name = args.first else { throw Failure(description: "scenario <name>") }
            await model.startScenario(name)
            try await waitIdle(model)
            return describe(model.session) + (Scenarios.lastNote.map { "; " + $0 } ?? "")
        case "continue":
            await model.continueNewest()
            try await waitIdle(model)
            return describe(model.session)
        case "load":
            // load [index] (0 = newest)
            await model.refreshSaves()
            let index = args.first.flatMap { Int($0) } ?? 0
            guard model.saves.indices.contains(index) else { throw Failure(description: "no save \(index) of \(model.saves.count)") }
            await model.load(model.saves[index])
            try await waitIdle(model)
            return describe(model.session)
        case "saves":
            await model.refreshSaves()
            let unreadable = model.unreadableSaves.map { "\($0.url.lastPathComponent)[\($0.isOtherVersion ? "other version" : "damaged")]" }
            return (model.saves.map { "\($0.url.lastPathComponent)[\($0.kind.rawValue), turn \($0.turn)]" } + unreadable)
                .joined(separator: ", ")
        case "quit":
            await model.quitToMenu()
            return "start screen"
        case "loadsheet":
            // loadsheet [off]: the Load Game sheet
            model.isShowingLoad = args.first != "off"
            try await Task.sleep(for: .milliseconds(700))
            return "\(model.isShowingLoad)"
        case "orientation":
            guard let name = args.first else { throw Failure(description: "orientation portrait|landscape") }
            DebugOrientation.request(name)
            try await Task.sleep(for: .milliseconds(600))
            return name
        case "wait":
            let seconds = args.first.flatMap { Double($0) } ?? 1
            try await Task.sleep(for: .seconds(seconds))
            return ""
        case "wait-idle":
            try await waitIdle(model)
            return describe(model.session)
        default:
            break
        }

        guard let session = model.session else { throw Failure(description: "no game on screen") }
        switch verb {
        case "tap", "tapcity":
            let hex = try self.hex(args, session)
            let view = session.view
            let hit: MapHit
            if verb == "tapcity", let city = view.knownCity(at: hex) {
                hit = .city(id: city.id.rawValue, hex)
            } else if !view.units(at: hex).isEmpty {
                hit = .unit(hex)
            } else if let city = view.knownCity(at: hex) {
                hit = .city(id: city.id.rawValue, hex)
            } else {
                hit = .ground(hex)
            }
            session.notices.acknowledge() // a tap, as on the map (MapView)
            session.handleTap(hit)
            return selectionText(session)
        case "longpress":
            // The hex inspected, and the tile sheet's tribal village line ("seen now", "remembered").
            session.notices.acknowledge()
            session.inspect(try hex(args, session))
            guard let inspected = session.inspectedHex else { return "" }
            let village = session.view.tileFacts(at: inspected)?.tribalVillage.map { " · tribal village: " + TileSheet.tribalVillageState($0) }
            return inspected.description + (village ?? "")
        case "select":
            guard args.count >= 2, let id = Int(args[1]) else {
                session.deselect()
                return "none"
            }
            switch args[0] {
            case "unit": session.select(.unit(UnitID(id)))
            case "city": session.select(.city(CityID(id)))
            default: throw Failure(description: "select unit <id> | select city <id> | select none")
            }
            return selectionText(session)
        case "deselect":
            session.deselect()
            return ""
        case "command":
            let command = try parseCommand(args, session)
            guard session.perform(command) else { throw Failure(description: session.message ?? "refused") }
            return session.message ?? ""
        case "attack":
            // attack: confirm the previewed attack
            guard session.pendingAttack != nil else { throw Failure(description: "no attack previewed") }
            session.confirmAttack()
            return session.message ?? ""
        case "next":
            // next: Next (visits the next attention item, or ends the turn when none is left)
            let item = session.nextAttentionItem
            session.performNextAction()
            if item == nil {
                try await waitIdle(model, timeout: .seconds(300))
                return "ended the turn -> turn \(session.state.turn)"
            }
            try await Task.sleep(for: .milliseconds(400))
            return "\(item!.description): " + openedText(session)
        case "attention":
            // The attention queue in order, and what Next visits next.
            let clock = ContinuousClock()
            let began = clock.now
            let items = session.attentionItems
            let next = session.nextAttentionItem(in: items)
            let ms = Double((clock.now - began) / .microseconds(1)) / 1000
            return "\(items.count) [" + items.map(\.description).joined(separator: ", ") + "] next "
                + (next?.description ?? "endTurn") + String(format: " (%.2f ms)", ms)
        case "research":
            // research <tech id or name>: a tap on that tech panel row (the panel opens first)
            let wanted = args.joined(separator: " ").lowercased()
            let options = session.view.researchOptions()
            guard let option = options.first(where: { $0.tech.rawValue.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                throw Failure(description: "research <tech>: " + options.map(\.tech.rawValue).joined(separator: ", "))
            }
            if session.openPanel != .research {
                session.openPanel = .research
                try await Task.sleep(for: .milliseconds(800))
            }
            let set = session.chooseResearch(option)
            if set { session.openPanel = nil }
            try await Task.sleep(for: .milliseconds(500))
            let now = session.view.researchOptions()
            let current = now.first(where: \.researching).map { "researching \($0.name)" + ($0.turns.map { ", \(turnsText($0))" } ?? "") }
            let target = now.first(where: { $0.isTarget && !$0.researching }).map { ", on the way to \($0.name)" } ?? ""
            return (set ? "" : (session.message ?? "not set") + "; ") + (current ?? "not researching") + target
                + (session.openPanel == .research ? "; panel open" : "; panel closed")
        case "civic":
            // civic <civic id or name>: a tap on that civic panel row (the panel opens first)
            let wanted = args.joined(separator: " ").lowercased()
            let options = session.view.civicOptions()
            guard let option = options.first(where: { $0.civic.rawValue.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                throw Failure(description: "civic <civic>: " + options.map(\.civic.rawValue).joined(separator: ", "))
            }
            if session.openPanel != .civics {
                session.openPanel = .civics
                try await Task.sleep(for: .milliseconds(800))
            }
            let set = session.chooseCivic(option)
            try await Task.sleep(for: .milliseconds(500))
            let now = session.view.civicOptions()
            let current = now.first(where: \.studying).map { "studying \($0.name)" + ($0.turns.map { ", \(turnsText($0))" } ?? "") }
            return (set ? "" : (session.message ?? "not set") + "; ") + (current ?? "not studying")
        case "government":
            // government <id>: adopts that government (the Adopt button)
            guard let id = args.first else { throw Failure(description: "government <id>") }
            let ok = session.perform(.setGovernment(government: id))
            return ok ? "government \(session.view.government?.name ?? id)" : (session.message ?? "not changed")
        case "policies":
            // policies [id ...]: slots exactly these policies (Apply in the government panel)
            if let problem = session.view.policiesProblem(args) { return "not set: " + problem }
            let ok = session.perform(.setPolicies(policies: args))
            return ok ? "policies " + session.view.policies.map(\.id).joined(separator: " ") : (session.message ?? "not set")
        case "hourglass":
            // The hourglass beside Next (shown while items are pending): ends the turn early,
            // asking "N items need attention — End Turn?" once per game.
            guard session.waitingFor == nil, session.state.outcome == nil, session.nextAttentionItem != nil else {
                throw Failure(description: "no hourglass: nothing is pending (Next ends the turn)")
            }
            let turn = session.state.turn
            session.requestEndTurn()
            if let n = session.endTurnPrompt { return "prompt: \(n) items" }
            try await waitIdle(model, timeout: .seconds(300))
            return "turn \(turn) -> \(session.state.turn)"
        case "requestendturn":
            // Return: ends the turn, or asks "N items need attention — End Turn?" (once per game)
            let turn = session.state.turn
            session.requestEndTurn()
            if let n = session.endTurnPrompt { return "prompt: \(n) items" }
            try await waitIdle(model, timeout: .seconds(300))
            return "turn \(turn) -> \(session.state.turn)"
        case "endturnprompt":
            // endturnprompt reset: the question will be asked again in this game
            session.endTurnAsked = false
            UserDefaults.standard.removeObject(forKey: GameSession.endTurnAskedKey)
            return "reset"
        case "confirm":
            // confirm yes|no: answers the confirmation on screen
            let yes = args.first != "no"
            return try await confirm(yes, session, model)
        case "queue":
            // queue add <item> | remove <index> | move <from> <to>, on the selected city
            guard let city = session.selectedCity, args.count >= 2 else { throw Failure(description: "queue add|remove|move … with a city selected") }
            let ok: Bool
            switch args[0] {
            case "add": ok = session.enqueue(try item(args[1], session), in: city.id)
            case "remove": ok = session.removeFromQueue(at: Int(args[1]) ?? -1, in: city.id)
            case "move":
                guard args.count >= 3, let from = Int(args[1]), let to = Int(args[2]) else { throw Failure(description: "queue move <from> <to>") }
                ok = session.moveInQueue(from: from, to: to, in: city.id)
            default: throw Failure(description: "queue add|remove|move")
            }
            guard ok else { throw Failure(description: session.message ?? "refused") }
            return (session.selectedCity?.queue.map { ItemName.of($0.item, rules: session.state.rules) } ?? []).joined(separator: ", ")
        case "buy":
            // buy <item>: the Buy button in the selected city's panel (may ask first)
            guard let city = session.selectedCity, let word = args.first else { throw Failure(description: "buy <item> with a city selected") }
            session.buy(try item(word, session), in: city.id)
            try await Task.sleep(for: .milliseconds(300))
            if let request = session.pendingPurchase { return "asks: \(request.price) of \(request.gold) gold" }
            return session.message ?? ""
        case "focus":
            guard let city = session.selectedCity, let focus = args.first.flatMap(CityFocus.init(rawValue:)) else {
                throw Failure(description: "focus balanced|food|production|gold with a city selected")
            }
            session.setFocus(focus, of: city.id)
            return session.selectedCity?.focus.rawValue ?? ""
        case "bombard":
            // bombard [cancel]: the selected city's Bombard button (target mode), or leaving it
            guard let city = session.selectedCity else { throw Failure(description: "no city selected") }
            if args.first == "cancel" {
                session.endBombard()
            } else {
                session.beginBombard(city.id)
            }
            try await Task.sleep(for: .milliseconds(300))
            return "targeting \(session.bombardTargeting.map { "\($0.rawValue)" } ?? "none"), " + selectionText(session)
        case "quarter":
            // quarter <kind>|cancel: a Quarters row of the selected city's panel (its tile
            // choice on the map), or leaving it; the result lists the marked sites.
            guard let city = session.selectedCity else { throw Failure(description: "no city selected") }
            if args.first == "cancel" {
                session.endQuarter()
            } else {
                guard let kind = args.first else { throw Failure(description: "quarter <kind>|cancel") }
                session.beginQuarter(QuarterKind(kind), in: city.id)
            }
            try await Task.sleep(for: .milliseconds(300))
            guard let placing = session.quarterPlacing else { return session.message ?? "placing none" }
            let sites = session.quarterSites().map { "\($0.tile.q) \($0.tile.r) +\($0.adjacency)" }
            return "placing \(placing.kind.rawValue): " + sites.joined(separator: ", ")
        case "buytile":
            // buytile [cancel]: the selected city's Buy tile (its tile choice on the map), or
            // leaving it; the result gives the price and the marked tiles.
            guard let city = session.selectedCity else { throw Failure(description: "no city selected") }
            if args.first == "cancel" { session.endBuyTile() } else { session.beginBuyTile(in: city.id) }
            try await Task.sleep(for: .milliseconds(300))
            guard let id = session.tileBuying, let purchase = session.view.tilePurchase(of: id) else {
                return session.message ?? "buying none"
            }
            return "buying for \(purchase.price): " + purchase.tiles.map { "\($0.q) \($0.r)" }.joined(separator: ", ")
        case "keep", "raze":
            guard case let .capture(id)? = session.attentionCard else { throw Failure(description: "no Keep/Raze card") }
            if verb == "keep" { session.keepCity(id) } else { session.askToRaze(id) }
            try await Task.sleep(for: .milliseconds(300))
            return session.pendingRaze != nil ? "asks to raze" : (session.message ?? selectionText(session))
        case "peace":
            // peace accept|decline: answers the peace card (or the first proposal)
            guard let answer = args.first, ["accept", "decline"].contains(answer) else { throw Failure(description: "peace accept|decline") }
            let from: PlayerID
            if case let .peace(player)? = session.attentionCard {
                from = player
            } else if let first = session.view.peaceProposals.first {
                from = first
            } else {
                throw Failure(description: "no peace proposal")
            }
            session.answerPeace(from: from, accept: answer == "accept")
            return session.message ?? "answered"
        case "declarewar":
            guard let id = args.first.flatMap({ Int($0) }) else { throw Failure(description: "declarewar <player>") }
            session.askToDeclareWar(on: PlayerID(id))
            try await Task.sleep(for: .milliseconds(300))
            return session.pendingWar != nil ? "asks" : (session.message ?? "")
        case "proposepeace":
            guard let id = args.first.flatMap({ Int($0) }) else { throw Failure(description: "proposepeace <player>") }
            session.proposePeace(to: PlayerID(id))
            return session.message ?? ""
        case "closecard":
            session.closeAttentionCard()
            return selectionText(session)
        case "aicommand":
            // aicommand <player> <command…>: the AI player issues it at the start of its next phase
            guard let id = args.first.flatMap({ Int($0) }), args.count > 1 else { throw Failure(description: "aicommand <player> <command…>") }
            let command = try parseCommand(Array(args.dropFirst()), session)
            session.debugPrelude[PlayerID(id), default: []].append(command)
            return "queued for player \(id)"
        case "warnload":
            // The alert a save with changed rules data shows when opened (M1 §14).
            model.presentLoadWarnings([.rulesDataChanged(rulesID: session.state.rules.id)])
            try await Task.sleep(for: .milliseconds(500))
            return model.alert?.title ?? ""
        case "alert":
            // alert ok: dismisses the app's alert
            let title = model.alert?.title ?? "none"
            model.alert = nil
            try await Task.sleep(for: .milliseconds(300))
            return title
        case "savemenu":
            // savemenu: the game menu's Save Game…, the prompt with the default name;
            // savemenu ok|cancel: the prompt's Save or Cancel
            switch args.first {
            case "ok":
                let name = session.saveName
                session.isShowingSave = false
                await session.save(named: name)
                await model.refreshSaves()
                return name
            case "cancel":
                session.isShowingSave = false
                try await Task.sleep(for: .milliseconds(400))
                return "cancelled"
            default:
                session.beginSave()
                try await Task.sleep(for: .milliseconds(600))
                return session.saveName
            }
        case "loadmenu":
            // The game menu's Load Game…: asks first when moves were made since the newest save
            if session.hasUnsavedCommands {
                session.confirmingLoad = true
            } else {
                model.isShowingLoad = true
            }
            try await Task.sleep(for: .milliseconds(700))
            return session.confirmingLoad ? "asks first" : "load list"
        case "endturn":
            // endturn [nowait]: ends the turn; waits for the other players' phases unless nowait.
            let turn = session.state.turn
            guard session.isInputEnabled else { throw Failure(description: "not the viewer's phase") }
            session.endTurn()
            if args.first == "nowait" { return "ending turn \(turn)" }
            try await waitIdle(model, timeout: .seconds(300))
            return "turn \(turn) -> \(session.state.turn)"
        case "zoom":
            // zoom close|standard|strategic|<scale>
            let presets = ["close": 0.6, "standard": 1.0, "strategic": 2.6]
            guard let scale = args.first.flatMap({ presets[$0.lowercased()] ?? Double($0) }) else {
                throw Failure(description: "zoom close|standard|strategic|<scale>")
            }
            session.renderer.setCameraScale(scale)
            return ""
        case "tapscreen":
            // tapscreen <x> <y>: a tap at a view point (points), banners first, as a finger would
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { throw Failure(description: "tapscreen <x> <y>") }
            session.notices.acknowledge()
            session.tapMap(at: CGPoint(x: x, y: y))
            return selectionText(session)
        case "tapbanner":
            guard let id = args.first.flatMap({ Int($0) }) else { throw Failure(description: "tapbanner <city id>") }
            session.notices.acknowledge()
            session.tapBanner(CityID(id))
            return selectionText(session)
        case "banners":
            // The banners shown, top-most first: id, name and rectangle (points); "(focus)"
            // over a focus tile ("(pill)": collapsed there), "(faded)" with its secondary rows
            // faded over a unit.
            try await Task.sleep(for: .milliseconds(100))
            let names = Dictionary(session.bannerModels().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let focused = Set(session.overlay.focusedBannerCities)
            let faded = Set(session.overlay.fadedBannerCities)
            let pills = Set(session.overlay.pillBannerCities)
            let shown = session.overlay.shownBannerCities.map { id -> String in
                let r = session.overlay.bannerRect(of: id) ?? .zero
                let shift = session.overlay.bannerShift(of: id)
                return "\(id.rawValue):\(names[id] ?? "?")@\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))"
                    + (focused.contains(id) ? "(focus)" : "") + (pills.contains(id) ? "(pill)" : "") + (faded.contains(id) ? "(faded)" : "")
                    + (shift < 0 ? "(up)" : shift > 0 ? "(down)" : "")
            }
            return "\(shown.count) of \(names.count) shown, strategic \(session.renderer.showsStrategicTokens): " + shown.joined(separator: " ")
        case "actions":
            // The selected unit's action bar, in order: kind, and why not.
            guard let unit = session.selectedUnit else { throw Failure(description: "no unit selected") }
            return UnitCard.ordered(session.view.unitActions(for: unit.id), unit: unit)
                .map { $0.kind.rawValue + ($0.problem.map { "(\($0))" } ?? "") }.joined(separator: " ")
        case "action":
            // action <kind>: a tap on an action tile (an unavailable one is described instead)
            guard let unit = session.selectedUnit, let kind = args.first.flatMap(UnitActionKind.init(rawValue:)),
                  let action = session.view.unitActions(for: unit.id).first(where: { $0.kind == kind }) else {
                throw Failure(description: "action <kind> with a unit selected")
            }
            if action.isAvailable {
                session.performAction(action)
            } else {
                session.describedAction = kind
            }
            return action.problem ?? session.message ?? ""
        case "describe":
            // describe <kind>|off: the action bar's description line (a long-press)
            session.describedAction = args.first.flatMap(UnitActionKind.init(rawValue:))
            return session.describedAction?.rawValue ?? "off"
        case "explore":
            // explore [on|off|describe|list]: the selected military unit's Explore tile (on: a tap
            // while it is not exploring, off: one while it is), its description, or the explorers.
            let arg = args.first ?? "on"
            if arg == "list" {
                let orders = session.explore.orders.map { order in
                    "\(order.unit.rawValue)" + (order.goal.map { "->(\($0.q),\($0.r))" } ?? "")
                        + (order.resting == true ? " resting" : "")
                        + (order.knownEnemies.isEmpty ? "" : " knows \(order.knownEnemies.map(\.rawValue))")
                }
                return orders.isEmpty ? "none" : orders.joined(separator: " ")
            }
            guard let unit = session.selectedUnit, session.canExplore(unit) else { throw Failure(description: "explore with an own military unit selected") }
            switch arg {
            case "on": if !session.isExploring(unit.id) { session.toggleExplore(unit.id) }
            case "off": if session.isExploring(unit.id) { session.toggleExplore(unit.id) }
            case "describe": session.describeExplore(unit.id)
            default: throw Failure(description: "explore [on|off|describe|list]")
            }
            let now = session.view.unit(unit.id) ?? unit
            // After Stop, the card's line (none: "not exploring"), never an older message.
            if arg == "off" { return session.exploreHint(of: now)?.text ?? "not exploring" }
            return session.exploreHint(of: now)?.text ?? session.message ?? (session.isExploring(unit.id) ? "exploring" : "not exploring")
        case "confirmpath":
            guard session.pendingPath != nil else { throw Failure(description: "no route previewed") }
            session.confirmPath()
            return selectionText(session)
        case "routeto":
            session.routeSelectedUnit(to: try hex(args, session))
            return selectionText(session)
        case "escape":
            session.escape()
            return selectionText(session)
        case "notices":
            // The notice card on screen (waiting for a tap or Next), the size of the log and its
            // unread rows.
            let card = session.notices.card.map { c in c.lines.map(\.text).joined(separator: " | ") + (c.more > 0 ? " (+\(c.more))" : "") }
            return (card ?? "no card") + (session.notices.cardWaits ? " (waits)" : "")
                + "; \(session.notices.log.count) logged, \(session.notices.unread) unread"
        case "noticelog" where args.first == "locate":
            // noticelog locate <i>: a tap on row i of the log (0: the top, newest), as its button
            guard args.count > 1, let i = Int(args[1]) else { throw Failure(description: "noticelog locate <row>") }
            let rows = NoticeLog.turns(session.notices.log).flatMap(\.notices)
            guard rows.indices.contains(i) else { throw Failure(description: "no row \(i) of \(rows.count)") }
            guard let place = rows[i].place else { throw Failure(description: "row \(i) has no place: \(rows[i].text)") }
            session.openPanel = nil
            session.locate(rows[i])
            try await Task.sleep(for: .milliseconds(600))
            return "camera to (\(place.q),\(place.r)): \(rows[i].text)"
        case "noticelog":
            // noticelog [n]: the last n notices of the log (default 10), oldest first: turn, kind, text.
            let n = args.first.flatMap { Int($0) } ?? 10
            return session.notices.log.suffix(max(1, n)).map { "t\($0.turn) \($0.kind.rawValue): \($0.text)" }.joined(separator: " | ")
        case "tapnotice":
            guard let card = session.notices.card else { throw Failure(description: "no notice card") }
            session.lookAt(card)
            return ""
        case "testgift":
            // testgift [gold|science|builder] [phase] [city] [q r]: a tribal village's gift to the viewer as a take shows it
            // (synthetic records; the state is unchanged): by the selected unit, or the capital's land (`city`), on its
            // tile or q r; as the viewer's own command, or as at its phase start (`phase`). The log's newest line.
            let words = args.map { $0.lowercased() }
            let view = session.view
            let amounts = view.rules.tribalVillages?.gifts
            let gift: TribalVillageGift = if words.contains("science") {
                .science(amounts?.science ?? 20, toward: view.me.researching)
            } else if words.contains("builder") {
                .builder(UnitID(9_999))
            } else {
                .gold(amounts?.gold ?? 50)
            }
            let city = words.contains("city") ? view.me.capital ?? view.cities.first?.id : nil
            let unit = city == nil ? session.selectedUnit.flatMap { $0.owner == session.viewer ? $0.id : nil } : nil
            let numbers = args.filter { Int($0) != nil }
            let place = numbers.count >= 2 ? try hex(Array(numbers.suffix(2)), session)
                : unit.flatMap { view.unit($0)?.position } ?? city.flatMap { view.city($0)?.position }
            guard let place, unit != nil || city != nil else { throw Failure(description: "testgift: select an own unit, or say city") }
            session.debugTribalVillageGift(gift, at: place, unit: unit, city: city, byViewer: !words.contains("phase"))
            try await waitIdle(model)
            return session.notices.log.last.map { "\($0.kind.rawValue) \($0.importance): \($0.text)" } ?? "nothing logged"
        case "testnotices":
            // Sample notices of each importance, for looking at the toast.
            let view = session.view
            let capital = view.cities.first
            session.notices.post([
                Notice(kind: .production, text: "\(capital?.name ?? "Rome") finished a Warrior", systemImage: "hammer.fill",
                       place: capital?.position, turn: view.turn),
                Notice(kind: .growth, text: "\(capital?.name ?? "Rome") grew to 3", systemImage: "person.2.fill", tone: .good,
                       place: capital?.position, turn: view.turn),
                Notice(kind: .warOnViewer, text: "Mongols declared war on you!", systemImage: "flame.fill", tone: .bad,
                       importance: .alarm, turn: view.turn),
            ])
            return ""
        case "panel":
            // panel research|tech|civics|government|governments|diplomacy|notices|close, or panel city <id>|production|overview|yields|defence:
            // opens a panel (the city's at one of its parts), or closes the open one
            switch args.first {
            case "research", "tech": session.openPanel = .research
            case "civics", "civic": session.openPanel = .civics
            case "government", "policies": session.openPanel = .government
            case "governments":
                session.panelAnchor = GovernmentPanel.governmentsAnchor
                session.openPanel = .government
            case "diplomacy": session.openPanel = .diplomacy
            case "notices", "log": session.openPanel = .notices
            case "city":
                guard args.count > 1, let id = Int(args[1]) else { throw Failure(description: "panel city <id>") }
                session.select(.city(CityID(id)))
            case "production": session.requestCityPanel(.production)
            case "overview": session.requestCityPanel(.overview)
            case "yields": session.requestCityPanel(.yields)
            case "defence": session.requestCityPanel(.defence)
            case "close":
                session.openPanel = nil
                model.isShowingLoad = false
                if case .city? = session.selection { session.deselect() } // its panel closes, as Esc
            default: throw Failure(description: "panel research|tech|civics|government|governments|diplomacy|notices|city <id>|production|overview|yields|defence|close")
            }
            try await Task.sleep(for: .milliseconds(800))
            return openedText(session)
        case "flyover":
            // flyover [off]: a continuous eastward pan (frame rate while scrolling)
            session.flyover = args.first != "off"
            return "\(session.flyover)"
        case "framestats":
            // The renderer's stats line and the overlay's, as the developer readout shows them.
            return session.renderer.statsLine + String(format: " · %d banners · overlay %.2f ms", session.overlay.shownBanners,
                                                       session.overlay.layoutMilliseconds)
        case "slowmo":
            // slowmo <factor>: event animations and damage numbers that many times slower (1: normal)
            let factor = max(0.05, args.first.flatMap { Double($0) } ?? 1)
            session.renderer.animationSpeed = Float(1 / factor)
            session.overlay.timeScale = factor
            return "\(factor)"
        case "center":
            if args.first == "selection", let hex = session.selectionHex {
                session.renderer.centerCamera(on: hex, animated: false)
            } else if args.first == "unit", args.count > 1, let id = Int(args[1]), let unit = session.view.unit(UnitID(id)) {
                session.renderer.centerCamera(on: unit.position, animated: false)
            } else if args.first == "city", args.count > 1, let id = Int(args[1]),
                      let city = session.view.knownCities.first(where: { $0.id == CityID(id) }) {
                session.renderer.centerCamera(on: city.position, animated: false)
            } else {
                session.renderer.centerCamera(on: try hex(args, session), animated: false)
            }
            return ""
        case "diagnostic":
            session.diagnostic = args.first != "off"
            return "\(session.diagnostic)"
        case "quickai":
            session.quickAITurns = args.first != "off"
            return "\(session.quickAITurns)"
        case "aidriver":
            guard let driver = args.first.flatMap(AIDriver.init(rawValue:)) else { throw Failure(description: "aidriver real|scripted|random") }
            session.aiDriver = driver
            return driver.rawValue
        case "save":
            let name = args.joined(separator: " ")
            guard let summary = await session.save(named: name) else { throw Failure(description: session.message ?? "save failed") }
            await model.refreshSaves()
            return summary.url.lastPathComponent
        case "dump":
            try dump(session)
            return Self.stateFile.lastPathComponent
        case "stats":
            session.showStats = args.first != "off"
            return ""
        default:
            throw Failure(description: "unknown command \(verb)")
        }
    }

    /// Waits until nothing is going on: no world being made, no AI phase, no animation, no save
    /// being written.
    private func waitIdle(_ model: AppModel, timeout: Duration = .seconds(60)) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let session = model.session
            let busy = model.busy != nil || session.map { $0.isPlayingOtherPhases || $0.renderer.isAnimating || $0.isSaving } ?? false
            if !busy { break }
            guard ContinuousClock.now < deadline else { throw Failure(description: "still busy after \(timeout)") }
            try await Task.sleep(for: .milliseconds(50))
        }
        // A beat for SwiftUI and the map to draw the result.
        try await Task.sleep(for: .milliseconds(250))
    }

    private func hex(_ args: [String], _ session: GameSession) throws -> HexCoord {
        guard args.count >= 2, let q = Int(args[0]), let r = Int(args[1]), let hex = session.view.normalize(HexCoord(q: q, r: r)) else {
            throw Failure(description: "expected axial coordinates q r")
        }
        return hex
    }

    private func selectionText(_ session: GameSession) -> String {
        if let plan = session.pendingAttack { return "attack preview on \(plan.option.target)" }
        if let path = session.pendingPath { return "path to \(path.destination?.description ?? "?") in \(path.turns) turns" }
        if let hex = session.inspectedHex { return "\(session.inspectMode == .tile ? "tile sheet" : "info card") \(hex)" }
        switch session.selection {
        case let .unit(id)?: return "unit \(id.rawValue)"
        case let .city(id)?: return "city \(id.rawValue)"
        case nil: return "nothing selected"
        }
    }

    /// What the last step opened: the card, the panel or sheet, and the selection.
    private func openedText(_ session: GameSession) -> String {
        var parts: [String] = []
        if let card = cardName(session) { parts.append("card \(card)") }
        if let panel = session.openPanel { parts.append("panel \(panel)") }
        if session.selectedCity != nil, session.bombardTargeting == nil {
            parts.append("city panel (\(session.cityPanelRequest.focus))")
        }
        parts.append(selectionText(session))
        return parts.joined(separator: ", ")
    }

    /// Answers the confirmation on screen: End Turn with items pending, Buy, Raze, Declare War,
    /// Disband, or loading another game.
    private func confirm(_ yes: Bool, _ session: GameSession, _ model: AppModel) async throws -> String {
        let answered: String
        if let n = session.endTurnPrompt {
            session.answerEndTurnPrompt(endTurn: yes)
            answered = "endTurn (\(n) items)"
            if yes { try await waitIdle(model, timeout: .seconds(300)) }
        } else if let request = session.pendingPurchase {
            if yes { session.confirmPurchase() } else { session.pendingPurchase = nil }
            answered = "buy \(request.name)"
        } else if let city = session.pendingRaze {
            if yes { session.confirmRaze() } else { session.pendingRaze = nil }
            answered = "raze city \(city.rawValue)"
        } else if let player = session.pendingWar {
            if yes { session.confirmWar() } else { session.pendingWar = nil }
            answered = "war on player \(player.rawValue)"
        } else if let unit = session.pendingDisband {
            if yes { session.confirmDisband() } else { session.pendingDisband = nil }
            answered = "disband unit \(unit.rawValue)"
        } else if session.confirmingLoad {
            session.confirmingLoad = false
            if yes { model.isShowingLoad = true }
            answered = "load"
        } else {
            throw Failure(description: "no confirmation on screen")
        }
        try await Task.sleep(for: .milliseconds(400))
        return answered + (yes ? " yes" : " no") + (session.message.map { ": \($0)" } ?? "")
    }

    private func item(_ word: String, _ session: GameSession) throws -> ProductionItem {
        if let type = UnitType(rawValue: word.lowercased()) { return .unit(type) }
        if session.state.rules.building(BuildingID(word)) != nil { return .building(BuildingID(word)) }
        throw Failure(description: "no unit or building \(word)")
    }

    /// The bottom card on screen.
    private func cardName(_ session: GameSession) -> String? {
        if session.state.outcome != nil { return "gameOver" }
        if let card = session.attentionCard { return card.name }
        if session.pendingAttack != nil { return "combatPreview" }
        if session.bombardTargeting != nil { return "bombardTargets" }
        if session.inspectedHex != nil { return session.inspectMode == .tile ? "tileSheet" : "infoCard" }
        if session.selectedUnit != nil { return "unit" }
        return nil
    }

    private func describe(_ session: GameSession?) -> String {
        guard let session else { return "start screen" }
        let s = session.state
        return "turn \(s.turn), player \(s.currentPlayer.rawValue), \(session.view.units.count) units, \(session.view.cities.count) cities"
    }

    // MARK: Command grammar

    /// `found <unit>`, `move <unit> <q> <r>`, `attack <unit> <q> <r>`, `bombard <city> <q> <r>`,
    /// `fortify|sleep|wake|skip|disband|cancel <unit>`, `build <unit> farm|mine|pasture`,
    /// `research <tech>`, `queue <city> <item>…` (unit types or building ids), `buy <city> <item>`,
    /// `focus <city> <focus>`, `war <player>`, `peace <player>`, `accept|decline <player>`,
    /// `raze <city>`, `endturn`, or `json <Command as JSON>`.
    private func parseCommand(_ args: [String], _ session: GameSession) throws -> Command {
        guard let verb = args.first?.lowercased() else { throw Failure(description: "command <verb> …") }
        let rest = Array(args.dropFirst())
        func int(_ i: Int) throws -> Int {
            guard rest.indices.contains(i), let n = Int(rest[i]) else { throw Failure(description: "argument \(i + 1) of \(verb) must be a number") }
            return n
        }
        func unit() throws -> UnitID { UnitID(try int(0)) }
        func city() throws -> CityID { CityID(try int(0)) }
        func target() throws -> HexCoord { HexCoord(q: try int(1), r: try int(2)) }
        func item(_ word: String) throws -> ProductionItem {
            if let type = UnitType(rawValue: word.lowercased()) { return .unit(type) }
            if session.state.rules.building(BuildingID(word)) != nil { return .building(BuildingID(word)) }
            throw Failure(description: "no unit or building \(word)")
        }
        switch verb {
        case "found": return .foundCity(unit: try unit())
        case "move": return .moveUnit(unit: try unit(), to: try target())
        case "attack": return .attack(unit: try unit(), target: try target())
        case "bombard": return .cityAttack(city: try city(), target: try target())
        case "fortify": return .fortify(unit: try unit())
        case "sleep": return .sleep(unit: try unit())
        case "wake": return .wake(unit: try unit())
        case "skip": return .skip(unit: try unit())
        case "disband": return .disband(unit: try unit())
        case "cancel": return .cancelOrders(unit: try unit())
        case "build":
            guard rest.count > 1, let improvement = Improvement.allCases.first(where: { "\($0)" == rest[1].lowercased() }) else {
                throw Failure(description: "build <unit> farm|mine|pasture")
            }
            return .buildImprovement(unit: try unit(), improvement: improvement)
        case "research":
            guard let tech = rest.first else { throw Failure(description: "research <tech>") }
            return .setResearch(tech: TechID(tech))
        case "queue": return .setQueue(city: try city(), items: try rest.dropFirst().map(item))
        case "buy":
            guard rest.count > 1 else { throw Failure(description: "buy <city> <item>") }
            return .purchase(city: try city(), item: try item(rest[1]))
        case "focus":
            guard rest.count > 1, let focus = CityFocus(rawValue: rest[1]) else { throw Failure(description: "focus <city> <focus>") }
            return .setFocus(city: try city(), focus: focus)
        case "war": return .declareWar(on: PlayerID(try int(0)))
        case "peace": return .proposePeace(to: PlayerID(try int(0)))
        case "accept": return .respondToPeace(from: PlayerID(try int(0)), accept: true)
        case "decline": return .respondToPeace(from: PlayerID(try int(0)), accept: false)
        case "raze": return .razeCity(city: try city())
        case "endturn": return .endTurn
        case "json":
            let json = rest.joined(separator: " ")
            do {
                return try JSONDecoder().decode(Command.self, from: Data(json.utf8))
            } catch {
                throw Failure(description: "bad command JSON: \(error)")
            }
        default:
            throw Failure(description: "unknown command verb \(verb)")
        }
    }

    // MARK: State dump

    /// Writes what the viewer knows (and a little more) as JSON, so scripts can find their
    /// units, cities and targets: `Documents/automation-state.json`.
    private func dump(_ session: GameSession) throws {
        let view = session.view
        let state = session.state
        func hex(_ h: HexCoord) -> [String: Int] { ["q": h.q, "r": h.r, "col": h.offset.col, "row": h.offset.row] }
        func optional(_ value: Any?) -> Any { value ?? NSNull() }
        var object: [String: Any] = [
            "turn": state.turn,
            "currentPlayer": state.currentPlayer.rawValue,
            "phaseCount": state.phaseCount,
            "outcome": optional(state.outcome.map { "\($0)" }),
            "stateHash": String(state.stateHash(), radix: 16),
            "gold": view.me.gold,
            "researching": optional(view.me.researching?.rawValue),
            "diagnostic": session.diagnostic,
            "inputEnabled": session.isInputEnabled,
            "message": optional(session.message),
            "selection": selectionText(session),
            "cameraScale": session.renderer.camera.scale,
            "strategic": session.renderer.showsStrategicTokens,
            "commandsSinceSave": session.commandCount - session.savedCommandCount,
            "card": optional(cardName(session)),
            "pendingPathTurns": optional(session.pendingPath.map(\.turns)),
            "notice": optional(session.notices.card.map { $0.lines.map(\.text).joined(separator: " | ") }),
            "noticesLogged": session.notices.log.count,
            "bannersShown": session.overlay.shownBanners,
            "bannersKnown": session.bannerModels().count,
            "overlayMs": session.overlay.layoutMilliseconds,
            "attention": session.attentionItems.map(\.description),
            "nextItem": optional(session.nextAttentionItem?.description),
            "attentionCard": optional(session.attentionCard?.name),
            "openPanel": optional(session.openPanel.map { "\($0)" }),
            "government": optional(session.view.government?.id),
            "policies": session.view.policies.map(\.id),
            "studying": optional(session.view.me.studying?.rawValue),
            "influence": session.view.me.influence ?? 0,
            // What the HUD covers (points): the camera centres in the rest.
            "mapInsets": ["top": Double(session.mapInsets.top), "left": Double(session.mapInsets.left),
                          "bottom": Double(session.mapInsets.bottom), "right": Double(session.mapInsets.right)],
            // The view's size and where the selection stands in it (points), and whether that is
            // in the open part the panels leave.
            "viewSize": [Double(session.renderer.camera.viewSize.x), Double(session.renderer.camera.viewSize.y)],
            "selectionPoint": optional(session.selectionHex.flatMap { session.renderer.screenPoint(of: $0) }.map { [Double($0.x), Double($0.y)] }),
            "selectionInOpen": optional(session.selectionHex.map { session.isOnScreen($0, margin: 0) }),
            "cityPanel": optional(session.selectedCity.map { _ in "\(session.cityPanelRequest.focus)" }),
            "bombardTargeting": optional(session.bombardTargeting?.rawValue),
            "quarterPlacing": optional(session.quarterPlacing.map { "\($0.city.rawValue) \($0.kind.rawValue)" }),
            "tileBuying": optional(session.tileBuying?.rawValue),
            "endTurnPrompt": optional(session.endTurnPrompt),
            "pendingPurchase": optional(session.pendingPurchase.map { "\($0.name) \($0.price)" }),
            "pendingRaze": optional(session.pendingRaze?.rawValue),
            "pendingWar": optional(session.pendingWar?.rawValue),
            "peaceProposals": session.view.peaceProposals.map(\.rawValue),
            // The tribal villages the viewer knows (seen now or remembered) and its gifts so far.
            "tribalVillages": view.knownTribalVillages.map { t -> [String: Any] in
                let h = view.coord(at: Int(t))
                var entry: [String: Any] = hex(h)
                entry["seen"] = view.isVisible(h)
                return entry
            },
            "tribalVillageGifts": view.tribalVillageGiftsReceived,
        ]
        object["units"] = view.units.map { u -> [String: Any] in
            ["id": u.id.rawValue, "type": u.type.rawValue, "at": hex(u.position), "moves": u.movesLeft, "hp": u.hp,
             "activity": u.activity.rawValue, "attackTargets": view.attackOptions(for: u.id).map { hex($0.target) }]
        }
        object["cities"] = view.cities.map { c -> [String: Any] in
            ["id": c.id.rawValue, "name": c.name, "at": hex(c.position), "population": c.population, "hp": c.hp,
             "queue": c.queue.map { ItemName.of($0.item, rules: state.rules) }, "focus": c.focus.rawValue,
             "storedProgress": c.storedProgress, "capturedTurn": optional(c.capturedTurn),
             "bombardTargets": view.cityAttackOptions(for: c.id).map { hex($0.target) }]
        }
        object["knownCities"] = view.knownCities.map { c -> [String: Any] in
            ["id": c.id.rawValue, "name": c.name, "owner": c.owner.rawValue, "at": hex(c.position), "population": c.population, "hp": c.hp]
        }
        object["visibleForeignUnits"] = view.visibleForeignUnits.map { u -> [String: Any] in
            ["id": u.id.rawValue, "owner": u.owner.rawValue, "type": u.type.rawValue, "at": hex(u.position), "hp": u.hp]
        }
        object["players"] = view.players.map { p -> [String: Any] in
            ["id": p.id.rawValue, "civ": p.civ.rawValue, "alive": p.isAlive, "score": p.score, "met": view.hasMet(p.id),
             "atWar": view.isAtWar(with: p.id)]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.stateFile, options: .atomic)
    }
}
#endif
