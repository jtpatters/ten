import GameCore
import SwiftUI

/// The combat preview (M1 §8.4, §16), from the tile the attack is made from: each side's
/// strength with its named modifiers, its health now and as the fight is likely to leave it (a
/// city's walls taking the damage first), the damage each side takes (range and expected), the
/// chance the defender is destroyed (a city brought to 0 HP, or taken when this attack takes it)
/// and the chance the attacker falls, and a one-line verdict with its hints (`combatCard`).
/// Attack (or Fire) confirms, as does tapping the target again.
struct AttackCard: View {
    let session: GameSession
    let plan: GameSession.AttackPlan
    var compact = false

    var body: some View {
        let view = session.view
        VStack(alignment: .leading, spacing: HUD.Space.s) {
            CardHeader(title: title, systemImage: plan.preview?.ranged == true ? "scope" : "burst.fill",
                       onClose: { session.cancelAttack() })
            if let p = plan.preview {
                let card = view.combatCard(for: p)
                HStack(alignment: .top, spacing: HUD.Space.s) {
                    CombatSideView(side: side(p.attacker, view), numbers: card.attacker, strength: p.attackerStrength,
                                   odds: card.deathOdds, oddsLabel: "chance to fall", oddsLikely: card.deathLikely, oddsAreBad: true)
                    Text("vs")
                        .font(HUD.body(.caption).italic())
                        .foregroundStyle(HUD.inkSoft)
                        .padding(.top, 6)
                    CombatSideView(side: side(p.defender, view), numbers: card.defender, strength: p.defenderStrength,
                                   odds: card.killOdds, oddsLabel: card.killLabel, oddsLikely: card.killLikely, oddsAreBad: false)
                }
                verdict(card)
                ForEach(card.notes, id: \.self) { note in
                    Hint(systemImage: "info.circle", text: note)
                }
                // What may strike the shooter later where it ends (a bombard, enemies next to it).
                ForEach(card.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Where a melee winner (or a capture) moves in, within reach of enemy bombards: in
                // the bad tone when what it keeps is below their typical blow.
                if let moveIn = card.moveIn {
                    Label(moveIn.text, systemImage: "exclamationmark.triangle")
                        .font(HUD.body(.caption))
                        .foregroundStyle(moveIn.severe ? HUD.danger : HUD.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case let .unit(id) = plan.attacker, let unit = view.unit(id), plan.option.from != unit.position {
                    Hint(systemImage: "arrow.turn.down.right", text: "Moves to the marked tile first, then attacks.")
                }
                if p.capturesCivilians {
                    Hint(systemImage: "person.fill.checkmark", text: "Civilians there are captured if it wins and moves in.")
                }
            } else {
                Text("The odds can't be judged from here.").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
            }
            HStack(spacing: HUD.Space.s) {
                Button {
                    session.confirmAttack()
                } label: {
                    Label(plan.preview?.ranged == true ? (Self.isCity(plan.attacker) ? "Bombard" : "Fire") : "Attack",
                          systemImage: "burst.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BronzeButtonStyle())
                .disabled(!session.isInputEnabled)
                .accessibilityHint("Tapping the target again does the same.")
                Button("Cancel") { session.cancelAttack() }
                    .buttonStyle(ParchmentButtonStyle())
            }
        }
        .hudCard()
    }

    private var title: String {
        if case .city = plan.attacker { return "Bombard" }
        return plan.preview?.ranged == true ? "Ranged Attack" : "Attack"
    }

    private static func isCity(_ side: Combatant) -> Bool {
        if case .city = side { true } else { false }
    }

    /// Who fights: name and owner.
    private func side(_ combatant: Combatant, _ view: PlayerView) -> CombatSideView.Side {
        switch combatant {
        case let .unit(id):
            let unit = view.unit(id)
            return .init(name: unit?.type.displayName ?? "Unit", owner: unit?.owner)
        case let .city(id):
            if let own = view.city(id) { return .init(name: own.name, owner: own.owner) }
            let known = view.knownCities.first { $0.id == id }
            return .init(name: known?.name ?? "City", owner: known?.owner)
        }
    }

    /// One line on what the fight is likely to do.
    private func verdict(_ card: CombatCard) -> some View {
        let icon = switch card.tone {
        case .bad: "exclamationmark.triangle.fill"
        case .good: "checkmark.seal.fill"
        case .neutral: "scalemass"
        }
        let tint = switch card.tone {
        case .bad: HUD.danger
        case .good: HUD.good
        case .neutral: HUD.inkSoft
        }
        return Label(card.verdict, systemImage: icon)
            .font(HUD.body(.footnote).weight(.semibold))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HUD.Space.s)
            .padding(.vertical, HUD.Space.xs + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .parchmentWell()
    }
}

/// One side of a previewed fight.
struct CombatSideView: View {
    struct Side {
        var name: String
        var owner: PlayerID?
    }

    var side: Side
    /// Its health and walls, now and as the fight is likely to leave them (`combatCard`).
    var numbers: CombatCardSide
    var strength: Strength
    /// The odds line ("62%", "<1%"), nil for none.
    var odds: String?
    var oddsLabel: String
    var oddsLikely: Bool
    /// The odds are of the viewer's loss (red when likely) rather than its win (green).
    var oddsAreBad: Bool

    var body: some View {
        let n = numbers
        let maxHP = Double(max(n.maxHP, 1))
        let walled = n.hasWalls || n.wallHP > 0
        VStack(alignment: .leading, spacing: HUD.Space.xs) {
            HStack(spacing: HUD.Space.xs) {
                if let owner = side.owner { PlayerEmblem(player: owner, size: 18) }
                Text(side.name).font(HUD.title(.subheadline)).lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(spacing: HUD.Space.xs) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 12, weight: .semibold))
                Text("\(strength.total)").font(HUD.numeric(.title3))
                if !strength.modifiers.isEmpty {
                    Text("base \(strength.base)").font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Strength \(strength.total)")
            ForEach(Array(strength.modifiers.enumerated()), id: \.offset) { _, modifier in
                HStack(spacing: HUD.Space.xs) {
                    Text(modifier.name).font(HUD.body(.caption2))
                    Spacer(minLength: HUD.Space.xs)
                    Text(YieldChip.signed(modifier.value)).font(HUD.numeric(.caption2))
                        .foregroundStyle(modifier.value < 0 ? HUD.danger : HUD.good)
                }
                .foregroundStyle(HUD.inkSoft)
            }
            if walled {
                WallBar(fraction: Double(n.wallHP) / Double(max(n.maxWallHP, 1)),
                        after: n.damage == nil ? nil : Double(n.wallHP - n.expectedWalls) / Double(max(n.maxWallHP, 1)))
                    .padding(.top, 2)
            }
            HealthBar(fraction: Double(n.hp) / maxHP, after: n.damage == nil ? nil : Double(n.hpAfter) / maxHP, height: 7)
                .padding(.top, walled ? 0 : 2)
            if let damage = n.damage {
                // One possible blow: exact numbers, no range and no "≈"; nor on a figure every roll
                // leaves the same (HP behind walls that take the largest blow).
                let exact = damage.lowerBound == damage.upperBound
                let aboutWalls = n.wallsAfterIsExact ? "" : "≈", about = n.hpAfterIsExact ? "" : "≈"
                HStack(spacing: HUD.Space.xs) {
                    Text(exact ? "Takes \(damage.lowerBound)" : "Takes \(damage.lowerBound)–\(damage.upperBound)").font(HUD.body(.caption))
                    if !exact {
                        Text("≈\(n.expected)").font(HUD.numeric(.caption)).foregroundStyle(HUD.inkSoft)
                    }
                }
                Text(walled ? "Walls \(n.wallHP) → \(aboutWalls)\(n.wallHP - n.expectedWalls) · HP \(n.hp) → \(about)\(n.hpAfter)"
                            : "HP \(n.hp) → \(about)\(n.hpAfter)" + (n.keepsOneIfItWins ? " if it wins" : ""))
                    .font(HUD.numeric(.caption2))
                    .foregroundStyle(HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Takes no damage").font(HUD.body(.caption)).foregroundStyle(HUD.inkSoft)
                Text(walled ? "Walls \(n.wallHP) · HP \(n.hp)" : "HP \(n.hp)").font(HUD.numeric(.caption2)).foregroundStyle(HUD.inkSoft)
            }
            if let odds {
                Text("\(odds) \(oddsLabel)")
                    .font(HUD.numeric(.caption).weight(.bold))
                    .foregroundStyle(oddsLikely ? (oddsAreBad ? HUD.danger : HUD.good) : HUD.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A city's walls as a thin stone-grey bar over its health bar; with `after`, the part the fight
/// may knock down is paler.
private struct WallBar: View {
    var fraction: Double
    var after: Double?

    static let stone = Color(red: 0.52, green: 0.55, blue: 0.60)

    var body: some View {
        let now = min(max(fraction, 0), 1)
        let then = min(max(after ?? now, 0), now)
        Capsule()
            .fill(HUD.ink.opacity(0.35))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let w = geometry.size.width
                    ZStack(alignment: .leading) {
                        if then < now {
                            Capsule().fill(Self.stone.opacity(0.4)).frame(width: max(4, w * now))
                        }
                        if then > 0 {
                            Capsule().fill(Self.stone).frame(width: max(4, w * then))
                        }
                    }
                }
                .padding(1)
            }
            .overlay(Capsule().stroke(HUD.ink.opacity(0.7), lineWidth: 1))
            .frame(height: 5)
            .accessibilityHidden(true)
    }
}
