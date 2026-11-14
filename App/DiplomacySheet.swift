import GameCore
import MapRendering
import SwiftUI

/// The diplomacy sheet (M1 §9, §16): the civilisations the viewer has met, each with its stance
/// and since when, its score, and what can be done now: Declare War (asked first) or Propose
/// Peace, each disabled with the reason and the turn it becomes possible; a proposal from them
/// to accept or decline, or the viewer's own awaiting an answer. Read-only in other phases.
struct DiplomacySheet: View {
    let session: GameSession
    var onDone: () -> Void

    var body: some View {
        let view = session.view
        // Civs only: the Free Cities are always at war and take no part in diplomacy (M2 §12.5).
        let others = view.players.filter { $0.id != session.viewer && $0.isMajor }
        let met = others.filter { view.hasMet($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Diplomacy", systemImage: "globe.europe.africa.fill", onClose: onDone)
                .padding(.horizontal, HUD.Space.l)
                .padding(.top, HUD.Space.l)
                .padding(.bottom, HUD.Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: HUD.Space.m) {
                    viewerRow(view)
                    if let waiting = session.waitingFor {
                        Label("Waiting for \(waiting.civName)", systemImage: "hourglass")
                            .font(HUD.body(.caption).weight(.semibold))
                            .foregroundStyle(HUD.inkSoft)
                    }
                    if met.isEmpty {
                        Text("You have not met another civilisation yet. Explore to find them.")
                            .font(HUD.body())
                            .foregroundStyle(HUD.inkSoft)
                            .padding(.vertical, HUD.Space.s)
                    }
                    ForEach(met, id: \.id) { player in
                        PlayerRelationRow(session: session, player: player)
                    }
                    if !view.knownMinors.isEmpty {
                        Button { session.openPanel = .minors } label: {
                            Label("Minor factions (\(view.knownMinors.count))", systemImage: "flag.2.crossed.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BronzeButtonStyle())
                    }
                    let unmet = others.count - met.count
                    if unmet > 0 {
                        Text("\(unmet) civilisation\(unmet == 1 ? "" : "s") not yet met.")
                            .font(HUD.body(.caption))
                            .foregroundStyle(HUD.inkSoft)
                    }
                    Text("At war, either side may attack the other and enter its lands. Peace can be proposed after \(view.rules.constants.diplomacy.peaceAfterWarTurns) turns of war; a treaty holds at least \(view.rules.constants.diplomacy.warAfterPeaceTurns) turns.")
                        .font(HUD.body(.caption2))
                        .foregroundStyle(HUD.inkSoft)
                        .padding(.top, HUD.Space.xs)
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.xl)
            }
        }
        .foregroundStyle(HUD.ink)
        .alert(warTitle, isPresented: Binding(get: { session.pendingWar != nil }, set: { if !$0 { session.pendingWar = nil } })) {
            Button("Declare War", role: .destructive) { session.confirmWar() }
            Button("Cancel", role: .cancel) { session.pendingWar = nil }
        } message: {
            Text("Their units may attack yours and enter your lands. Peace can be proposed after \(view.rules.constants.diplomacy.peaceAfterWarTurns) turns.")
        }
    }

    private var warTitle: String {
        session.pendingWar.map { "Declare war on \(session.civName(of: $0))?" } ?? ""
    }

    private func viewerRow(_ view: PlayerView) -> some View {
        HStack(spacing: HUD.Space.s) {
            PlayerEmblem(player: session.viewer, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.viewerCivName).font(HUD.title(.subheadline))
                Text("You").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
            Spacer()
            ScoreLabel(score: view.score(of: session.viewer))
        }
        .padding(.horizontal, HUD.Space.m)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).stroke(HUD.ink.opacity(0.2), lineWidth: 1))
    }
}

/// A score with its label.
private struct ScoreLabel: View {
    var score: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(score)").font(HUD.numeric(.headline))
            Text("score").font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One met civilisation: who, the stance, the score and the actions with their reasons.
private struct PlayerRelationRow: View {
    let session: GameSession
    let player: PlayerSummary

    var body: some View {
        let view = session.view
        let relation = view.relation(with: player.id)
        let atWar = view.isAtWar(with: player.id)
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            HStack(spacing: HUD.Space.s) {
                PlayerEmblem(player: player.id, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.civName(of: player.id)).font(HUD.title(.subheadline)).strikethrough(!player.isAlive)
                    if let leader = view.rules.civ(player.civ)?.leader {
                        Text(leader).font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                    }
                }
                Spacer(minLength: HUD.Space.s)
                ScoreLabel(score: player.score)
            }
            HStack(spacing: HUD.Space.s) {
                if !player.isAlive {
                    KindBadge(text: "Fallen")
                } else if atWar {
                    KindBadge(text: "At war", tint: HUD.danger)
                } else {
                    KindBadge(text: "At peace", tint: HUD.good)
                }
                if let since = relation?.since, player.isAlive {
                    Text("since turn \(since)").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                }
            }
            if player.isAlive { actions(view, relation: relation, atWar: atWar) }
        }
        .padding(HUD.Space.m)
        .parchmentWell(cornerRadius: HUD.Radius.medium)
    }

    @ViewBuilder
    private func actions(_ view: PlayerView, relation: Relation?, atWar: Bool) -> some View {
        let enabled = session.isInputEnabled
        if relation?.proposalFrom == player.id {
            VStack(alignment: .leading, spacing: HUD.Space.s) {
                Label(CivText.peaceProposal(from: player.id, in: session.view, civName: session.civName(of:)),
                      systemImage: "envelope.open.fill")
                    .font(HUD.body(.subheadline).weight(.semibold))
                HStack(spacing: HUD.Space.s) {
                    Button {
                        session.answerPeace(from: player.id, accept: true)
                    } label: {
                        Label("Accept", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BronzeButtonStyle())
                    Button {
                        session.answerPeace(from: player.id, accept: false)
                    } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ParchmentButtonStyle())
                }
                .opacity(enabled ? 1 : 0.6)
            }
        } else if relation?.proposalFrom == session.viewer {
            Label("Peace proposed; awaiting their answer", systemImage: "hourglass")
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
        } else if atWar {
            let problem = view.peaceProblem(to: player.id)
            actionButton("Propose Peace", systemImage: "leaf", problem: problem, destructive: false) {
                session.proposePeace(to: player.id)
            }
            // The AI never accepts before this many turns of war (M1 §13), and a refusal
            // delays the next proposal.
            if !player.isHuman, let since = relation?.since, view.turn < since + view.rules.ai.peaceMinWarTurns {
                Label("\(session.civName(of: player.id)) will not consider peace before turn \(since + view.rules.ai.peaceMinWarTurns)",
                      systemImage: "info.circle")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let problem = view.warProblem(on: player.id)
            actionButton("Declare War", systemImage: "flame", problem: problem, destructive: true) {
                session.askToDeclareWar(on: player.id)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, problem: String?, destructive: Bool,
                              action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: HUD.Space.xs) {
            Button(action: action) {
                Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
            }
            .buttonStyle(ParchmentButtonStyle(role: destructive ? .destructive : nil))
            .opacity(problem == nil ? 1 : 0.5)
            .accessibilityHint(problem.map { "Unavailable: \($0)." } ?? "")
            if let problem, problem != "not your turn" {
                Text(problem.prefix(1).uppercased() + problem.dropFirst() + ".")
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
            }
        }
    }
}

/// A minor faction's type as a glyph and a word (M2 §12).
enum MinorArt {
    static func symbol(_ type: MinorType) -> String {
        switch type {
        case .scientific: "flask.fill"
        case .cultural: "theatermasks.fill"
        case .trade: "bag.fill"
        case .militaristic: "shield.fill"
        case .industrial: "gearshape.fill"
        }
    }

    static func name(_ type: MinorType) -> String { type.rawValue.capitalized }
}

/// The minor factions the viewer has met (M2 §12): each one's type and bonuses, the envoys
/// there (the viewer's and everyone's), its Patron and quest, with Send Envoy and Levy, each
/// disabled with the reason.
struct MinorFactionSheet: View {
    let session: GameSession
    var onDone: () -> Void

    var body: some View {
        let view = session.view
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Minor Factions", systemImage: "flag.2.crossed.fill", onClose: onDone)
                .padding(.horizontal, HUD.Space.l)
                .padding(.top, HUD.Space.l)
                .padding(.bottom, HUD.Space.s)
            ScrollView {
                VStack(alignment: .leading, spacing: HUD.Space.m) {
                    Label("Envoy tokens: \(view.me.envoyTokens ?? 0)", systemImage: "person.wave.2.fill")
                        .font(HUD.body(.subheadline).weight(.semibold))
                    if view.knownMinors.isEmpty {
                        Text("You have not met a minor faction yet.").font(HUD.body()).foregroundStyle(HUD.inkSoft)
                    }
                    ForEach(view.knownMinors, id: \.player) { minor in
                        MinorFactionRow(session: session, minor: minor)
                    }
                    if let rules = view.rules.minors {
                        Text("Envoys give bonuses at each tier. The civ with the most envoys, at least \(rules.patronMinEnvoys), is the Patron: it shares the minor's resources and sight and may levy its army for \(rules.levyTurns) turns at \(rules.levyGoldPerUnit) Gold per unit.")
                            .font(HUD.body(.caption2))
                            .foregroundStyle(HUD.inkSoft)
                    }
                }
                .padding(.horizontal, HUD.Space.l)
                .padding(.bottom, HUD.Space.xl)
            }
        }
        .foregroundStyle(HUD.ink)
    }
}

private struct MinorFactionRow: View {
    let session: GameSession
    let minor: MinorFaction

    var body: some View {
        let view = session.view, rules = view.rules
        let me = session.viewer.rawValue
        let mine = minor.envoys.indices.contains(me) ? minor.envoys[me] : 0
        let all = minor.envoys.enumerated().filter { $0.element > 0 }
            .map { ($0.offset == me ? "You" : session.civName(of: PlayerID($0.offset))) + " \($0.element)" }
        let envoyProblem = view.envoyProblem(to: minor.player)
        let levyProblem = view.levyProblem(on: minor.player)
        let tiers = rules.minors?.type(minor.type)?.tiers ?? []
        let yield = rules.minors?.type(minor.type)?.yield.capitalized ?? ""
        VStack(alignment: .leading, spacing: HUD.Space.xs) {
            HStack(spacing: HUD.Space.s) {
                Image(systemName: MinorArt.symbol(minor.type))
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(Color(cgColor: Heraldry.color(minor.player)))
                    .background(Circle().fill(Color(uiColor: HUD.UI.cream)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.civName(of: minor.player)).font(HUD.title(.subheadline))
                    Text("\(MinorArt.name(minor.type)) minor faction").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                }
                Spacer()
                Text("\(mine) \(mine == 1 ? "envoy" : "envoys")").font(HUD.numeric(.footnote))
            }
            Text("Envoys: " + (all.isEmpty ? "none" : all.joined(separator: ", "))).font(HUD.body(.caption))
            Text("Patron: " + (minor.patron.map { $0 == session.viewer ? "You" : session.civName(of: $0) } ?? "none"))
                .font(HUD.body(.caption))
            if !tiers.isEmpty {
                Text(tiers.map { tier in
                    let where_ = tier.buildings.map { b in " in cities with " + b.map { rules.building($0)?.name ?? $0.rawValue }.joined(separator: " or ") } ?? " in the capital"
                    return "\(tier.envoys): +\(tier.amount) \(yield)\(where_)\(mine >= tier.envoys ? " ✓" : "")"
                }.joined(separator: " · "))
                .font(HUD.body(.caption))
                .foregroundStyle(HUD.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let quest = minor.quest {
                Label("Quest: " + questText(quest), systemImage: "scroll.fill").font(HUD.body(.caption).weight(.semibold))
            }
            if minor.quest == nil {
                Text("No quest now.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
            if let levy = minor.levy {
                Text("Army levied by \(levy.player == session.viewer ? "you" : session.civName(of: levy.player)) until turn \(levy.until)")
                    .font(HUD.body(.caption))
            }
            HStack(spacing: HUD.Space.s) {
                Button { _ = session.perform(.sendEnvoy(to: minor.player)) } label: {
                    Label("Send Envoy", systemImage: "person.wave.2.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
                .disabled(envoyProblem != nil || !session.isInputEnabled)
                .opacity(envoyProblem != nil ? 0.6 : 1)
                Button { _ = session.perform(.levy(minor: minor.player)) } label: {
                    Label("Levy", systemImage: "figure.2").frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
                .disabled(levyProblem != nil || !session.isInputEnabled)
                .opacity(levyProblem != nil ? 0.6 : 1)
            }
            if let envoyProblem { Text("Send Envoy: \(envoyProblem)").font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft) }
            if let levyProblem { Text("Levy: \(levyProblem)").font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft) }
        }
        .padding(HUD.Space.m)
        .background(RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous).stroke(HUD.ink.opacity(0.2), lineWidth: 1))
    }

    private func questText(_ quest: MinorQuest) -> String {
        let rules = session.view.rules
        switch quest.kind {
        case .clearCamp: return "clear the raider camp near " + session.civName(of: minor.player)
        case .building: return "build " + (quest.building.map { rules.building($0)?.name ?? $0.rawValue } ?? "a building")
        case .meetCivs: return "meet \(quest.count ?? 0) civilisations"
        case .envoys: return "have \(quest.count ?? 0) envoys at minor factions"
        case .trader: return "start a trade route to " + session.civName(of: minor.player)
        }
    }
}
