import GameCore
import SwiftUI

// The attention queue's cards and the Next button (M1 §16): Keep/Raze right after a capture, a
// peace proposal to answer, war declared on the viewer, upkeep about to disband units, other
// news; the hint while a city picks its bombard target; and Next / End Turn with the count of
// items pending.

/// The card of an attention item, at the bottom of the screen.
struct AttentionCardView: View {
    let session: GameSession
    let card: AttentionCard

    var body: some View {
        switch card {
        case let .capture(id): CaptureCard(session: session, city: id)
        case let .peace(player): PeaceCard(session: session, player: player)
        case let .war(player): WarCard(session: session, player: player)
        case .upkeep: UpkeepCard(session: session)
        case let .news(id): NewsCard(session: session, id: id)
        }
    }
}

/// Keep or raze a city just captured (M1 §5: only in the phase of its capture, never an
/// original capital). Raze asks first.
private struct CaptureCard: View {
    let session: GameSession
    let city: CityID

    var body: some View {
        let view = session.view
        if let c = view.city(city) {
            let problem = view.razeProblem(city)
            VStack(alignment: .leading, spacing: HUD.Space.s) {
                CardHeader(title: "You took \(c.name)!", player: c.owner, onClose: { session.closeAttentionCard() })
                Text(detail(c, view))
                    .font(HUD.body(.subheadline))
                    .foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                CardButtonRow {
                    Button {
                        session.keepCity(city)
                    } label: {
                        Label("Keep", systemImage: "flag.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BronzeButtonStyle())
                    Button {
                        session.askToRaze(city)
                    } label: {
                        Label("Raze", systemImage: "flame").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ParchmentButtonStyle(role: .destructive))
                    .opacity(problem == nil ? 1 : 0.5)
                    .accessibilityHint(problem.map { "Unavailable: \($0)." } ?? "Destroys the city.")
                }
                if let problem {
                    Hint(systemImage: "info.circle", text: problem.prefix(1).uppercased() + problem.dropFirst() + ".")
                }
            }
            .hudCard()
        }
    }

    private func detail(_ city: City, _ view: PlayerView) -> String {
        let people = city.population == 1 ? "1 citizen" : "\(city.population) citizens"
        let from = session.civName(of: city.originalOwner)
        if view.razeProblem(city.id) == nil {
            return "Founded by \(from), it has \(people). Keep it and its lands, or raze it to the ground — only now, in the turn of its capture."
        }
        return "Founded by \(from), it has \(people). Keep it and choose what it builds."
    }
}

/// A peace proposal to accept or decline (M1 §9).
private struct PeaceCard: View {
    let session: GameSession
    let player: PlayerID

    var body: some View {
        let view = session.view
        let since = view.relation(with: player)?.since
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            CardHeader(title: CivText.peaceProposal(from: player, in: view, civName: session.civName(of:)), player: player,
                       onClose: { session.closeAttentionCard() })
            Text(detail(since: since, view: view))
                .font(HUD.body(.subheadline))
                .foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HUD.Space.l) {
                Stat(systemImage: "flame", value: since.map { "\(max(0, view.turn - $0))" } ?? "—", label: "turns at war", tint: HUD.danger)
                Stat(systemImage: "crown", value: "\(view.score(of: player))", label: "their score")
                Stat(systemImage: "crown.fill", value: "\(view.score(of: session.viewer))", label: "your score", tint: HUD.gilt)
            }
            CardButtonRow {
                Button {
                    session.answerPeace(from: player, accept: true)
                } label: {
                    Label("Accept", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
                Button {
                    session.answerPeace(from: player, accept: false)
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(ParchmentButtonStyle())
            }
        }
        .hudCard()
    }

    private func detail(since: Int?, view: PlayerView) -> String {
        let years = view.rules.constants.diplomacy.warAfterPeaceTurns
        return "Peace would hold at least \(years) turns, and military units must leave each other's lands. Unanswered, the offer lapses at the start of their next turn."
    }
}

/// War declared on the viewer.
private struct WarCard: View {
    let session: GameSession
    let player: PlayerID

    var body: some View {
        let view = session.view
        let since = view.relation(with: player)?.since ?? view.turn
        let first = since + view.rules.constants.diplomacy.peaceAfterWarTurns
        // An AI never accepts peace before this many turns of war (M1 §13), and a refusal
        // delays the next offer: a proposal before then is wasted.
        let ai = view.players.first { $0.id == player }.map { !$0.isHuman } ?? false
        let listens = since + view.rules.ai.peaceMinWarTurns
        let peace = ai && listens > first ? "Peace can be proposed from turn \(first), but they will not consider it before turn \(listens)."
            : "Peace can be proposed from turn \(first)."
        // What is at stake: the army the viewer has seen, and in a duel the capital (M1 §10).
        let capital = view.capitalAtStake.flatMap { view.city($0) }
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            CardHeader(title: "\(session.civName(of: player)) declared war!", player: player, onClose: { session.closeAttentionCard() }) {
                KindBadge(text: "War", tint: HUD.danger)
            }
            Text("Their units may now attack yours and march into your lands. \(peace)")
                .font(HUD.body(.subheadline))
                .foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: HUD.Space.xs) {
                Label(armyText(view.rememberedArmy(of: player), view: view), systemImage: "binoculars.fill")
                    .font(HUD.body(.subheadline))
                    .foregroundStyle(HUD.ink)
                if let capital {
                    Label("If \(capital.name) falls, you lose the game.", systemImage: "exclamationmark.shield.fill")
                        .font(HUD.body(.subheadline).weight(.semibold))
                        .foregroundStyle(HUD.danger)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            CardButtonRow {
                Button {
                    session.closeAttentionCard()
                    session.openPanel = .diplomacy
                } label: {
                    Label("Diplomacy", systemImage: "globe.europe.africa").frame(maxWidth: .infinity)
                }
                .buttonStyle(ParchmentButtonStyle())
                Button {
                    session.closeAttentionCard()
                } label: {
                    Text("To Arms").frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
            }
        }
        .hudCard()
        .overlay {
            RoundedRectangle(cornerRadius: HUD.Radius.medium, style: .continuous)
                .stroke(HUD.danger.opacity(0.6), lineWidth: 2)
                .padding(2)
        }
    }

    /// "Last seen: 4 Mongol military units, the nearest 3 tiles from Antium." (sightings of the
    /// last turns, M1 §11), or that none was seen.
    private func armyText(_ army: RememberedArmy, view: PlayerView) -> String {
        let whose = CivText.adjective(of: player, in: view, civName: session.civName(of:))
        guard army.units > 0 else { return "You have seen no \(whose) military units lately." }
        let units = army.units == 1 ? "1 \(whose) military unit" : "\(army.units) \(whose) military units"
        guard let id = army.nearestCity, let city = view.city(id), let distance = army.distance else { return "Last seen: \(units)." }
        let tiles = distance == 1 ? "1 tile" : "\(distance) tiles"
        return "Last seen: \(units), \(army.units == 1 ? "" : "the nearest ")\(tiles) from \(city.name)."
    }
}

/// Upkeep the treasury cannot pay (M1 §7.1): units will be disbanded.
private struct UpkeepCard: View {
    let session: GameSession

    var body: some View {
        let view = session.view
        let forecast = view.upkeepForecast()
        let income = view.income()
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            CardHeader(title: "Units will be disbanded", systemImage: "circle.slash", onClose: { session.closeAttentionCard() })
            let finishing = forecast.completing == 0 ? ""
                : forecast.completing == 1 ? " The new unit your cities finish then adds to the upkeep."
                : " The \(forecast.completing) new units your cities finish then add to the upkeep."
            Text("Your treasury cannot pay the upkeep of every unit: at the start of your next turn \(forecast.disbanded == 1 ? "1 unit" : "\(forecast.disbanded) units") will be disbanded.\(finishing) Disband some yourself, or earn more gold.")
                .font(HUD.body(.subheadline))
                .foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HUD.Space.l) {
                Stat(systemImage: YieldChip.Kind.gold.systemImage, value: "\(view.me.gold)", label: "treasury", tint: HUD.Yield.gold)
                Stat(systemImage: "arrow.down.circle", value: "\(income.upkeep)", label: "upkeep per turn", tint: HUD.danger)
                Stat(systemImage: "shield.lefthalf.filled",
                     value: "\(income.militaryUnits)\(forecast.completing > 0 ? "+\(forecast.completing)" : "")/\(income.freeUnits)",
                     label: "units / free")
            }
            Button {
                session.closeAttentionCard()
            } label: {
                Text("Understood").frame(maxWidth: .infinity)
            }
            .buttonStyle(ParchmentButtonStyle())
        }
        .hudCard()
    }
}

/// An important notice (a city lost, a unit hurt, …) with a look at where it happened; for a
/// hurt unit (selected under the card), its health now; for a lost unit, the blows before.
private struct NewsCard: View {
    let session: GameSession
    let id: Int

    var body: some View {
        if let notice = session.newsNotice(id) {
            VStack(alignment: .leading, spacing: HUD.Space.s) {
                HStack(spacing: HUD.Space.s) {
                    Image(systemName: notice.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(notice.tone == .bad ? HUD.danger : (notice.tone == .good ? HUD.good : HUD.inkSoft))
                        .frame(width: 24)
                    Text(notice.text).font(HUD.title(.subheadline)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    CloseButton { session.closeAttentionCard() }
                }
                if let report = notice.damage {
                    health(report)
                }
                // A lost unit's earlier blows, kept from the item its loss replaced.
                if let earlier = notice.before {
                    Text("Before that: \(earlier.text)")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 32)
                }
                Button {
                    session.closeAttentionCard()
                } label: {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .buttonStyle(ParchmentButtonStyle())
            }
            .hudCard()
        }
    }

    /// A hurt unit's health now (it may have healed, or fallen since).
    @ViewBuilder
    private func health(_ report: DamageReport) -> some View {
        let view = session.view
        if let unit = view.unit(report.unit), unit.owner == session.viewer {
            let maxHP = view.rules.constants.healing.maxHP
            HStack(spacing: HUD.Space.s) {
                Text("Now \(unit.hp) HP")
                    .font(HUD.numeric(.caption))
                    .foregroundStyle(HUD.inkSoft)
                HealthBar(fraction: Double(unit.hp) / Double(max(1, maxHP)))
                    .frame(maxWidth: 140)
            }
            .padding(.leading, 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now \(unit.hp) of \(maxHP) HP")
        } else {
            Text("It has fallen since.")
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
                .padding(.leading, 32)
        }
    }
}

/// While a city picks its bombard target: what to do, and Cancel.
struct BombardHintCard: View {
    let session: GameSession
    let city: CityID

    var body: some View {
        let name = session.view.city(city)?.name ?? "The city"
        let targets = session.view.cityAttackOptions(for: city).count
        HStack(spacing: HUD.Space.m) {
            Image(systemName: "scope").font(.system(size: 18, weight: .semibold)).foregroundStyle(HUD.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) bombards").font(HUD.title(.subheadline))
                Text(targets == 1 ? "Tap the marked enemy." : "Tap one of the \(targets) marked enemies.")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
            }
            Spacer(minLength: HUD.Space.s)
            Button("Cancel") { session.endBombard() }
                .buttonStyle(ParchmentButtonStyle())
        }
        .hudCard()
    }
}

/// Placing a quarter (M2 §18.2): which, where, and Cancel.
struct QuarterHintCard: View {
    let session: GameSession
    let placing: QuarterPlacing

    var body: some View {
        let name = session.state.rules.quarter(placing.kind)?.name ?? placing.kind.rawValue
        let city = session.view.city(placing.city)?.name ?? "the city"
        let sites = session.quarterSites().count
        HStack(spacing: HUD.Space.m) {
            Image(systemName: QuarterArt.symbol(placing.kind)).font(.system(size: 18, weight: .semibold)).foregroundStyle(HUD.bronzeBottom)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) in \(city)").font(HUD.title(.subheadline))
                Text(sites == 1 ? "Tap the marked tile. Its number is the adjacency bonus."
                     : "Tap one of the \(sites) marked tiles. Numbers are adjacency bonuses.")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: HUD.Space.s)
            Button("Cancel") { session.endQuarter() }
                .buttonStyle(ParchmentButtonStyle())
        }
        .hudCard()
    }
}

/// Buying a tile (M2 §7.4): for which city, at what price, and Cancel.
struct BuyTileHintCard: View {
    let session: GameSession
    let city: CityID

    var body: some View {
        let name = session.view.city(city)?.name ?? "the city"
        let purchase = session.view.tilePurchase(of: city)
        let tiles = purchase?.tiles.count ?? 0
        HStack(spacing: HUD.Space.m) {
            Image(systemName: "square.dashed").font(.system(size: 18, weight: .semibold)).foregroundStyle(HUD.Yield.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("Buy a tile for \(name) · \(purchase?.price ?? 0) Gold").font(HUD.title(.subheadline))
                Text(tiles == 1 ? "Tap the marked tile." : "Tap one of the \(tiles) marked tiles.")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: HUD.Space.s)
            Button("Cancel") { session.endBuyTile() }
                .buttonStyle(ParchmentButtonStyle())
        }
        .hudCard()
    }
}

/// Next (Space): what the attention queue visits next, with how many items are pending, or End
/// Turn when none is; "Waiting for <civ>" in another player's phase. While items are pending,
/// the hourglass beside it (and its menu) ends the turn at once (asking once per game).
struct NextButton: View {
    let session: GameSession

    var body: some View {
        if let waiting = session.waitingFor {
            WaitingPill(player: waiting.player, civName: waiting.civName)
        } else if session.state.outcome == nil {
            let items = session.attentionItems
            let next = session.nextAttentionItem(in: items)
            HStack(spacing: HUD.Space.s) {
                if next != nil {
                    endTurnButton
                }
                nextButton(items: items, next: next)
            }
        }
    }

    /// End Turn with items pending: a small hourglass, so a touch screen can end the turn early.
    private var endTurnButton: some View {
        Button {
            session.requestEndTurn()
        } label: {
            Image(systemName: "hourglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HUD.ink)
                .frame(width: HUD.touch, height: HUD.touch)
                .parchmentCapsule()
                .contentShape(Circle())
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel("End Turn")
        .accessibilityHint("Ends your turn now, with items still pending.")
    }

    private func nextButton(items: [AttentionItem], next: AttentionItem?) -> some View {
        Button {
            session.performNextAction()
        } label: {
            HStack(spacing: HUD.Space.s) {
                // One line ("Peace Proposal" at the accessibility sizes): it scales down first.
                Label(next?.title ?? "End Turn", systemImage: next?.systemImage ?? "hourglass")
                    .lineLimit(1).minimumScaleFactor(0.7)
                if items.count > 1 {
                    Text("\(items.count)")
                        .font(HUD.numeric(.caption))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(HUD.ink.opacity(0.14)))
                        .accessibilityLabel("\(items.count) items need attention")
                }
            }
        }
        .buttonStyle(BronzeButtonStyle())
        .keyboardShortcut(.space, modifiers: [])
        .contextMenu {
            if next != nil {
                Button {
                    session.requestEndTurn()
                } label: {
                    Label("End Turn", systemImage: "hourglass")
                }
            }
        }
        .accessibilityHint(next == nil ? "Ends your turn." : "Shows the next thing that needs your attention. Hold, or use the hourglass, to end the turn.")
    }
}
