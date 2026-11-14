import GameCore
import MapGen
import SwiftUI

// Shared pieces of the game screen's panels (M1 §16), all reading through the viewer's
// `PlayerView`: the game-over card, item and tile names, and small views. The panels have
// their own files: `TopBar.swift`, `UnitCard.swift`, `CityPanel.swift`, `CombatCards.swift`
// (combat preview), `InfoCards.swift` (info card and tile sheet), `TechPanel.swift`,
// `DiplomacySheet.swift`, `AttentionCards.swift` (the attention queue's cards and Next).

enum ItemName {
    static func of(_ item: ProductionItem, rules: Ruleset) -> String {
        switch item {
        case let .unit(type): type.displayName
        case let .building(id): rules.building(id)?.name ?? id.rawValue.capitalized
        case let .quarter(kind, _): rules.quarter(kind)?.name ?? kind.rawValue.capitalized
        }
    }

    /// "a Warrior", "an Archer", "a Monument".
    static func withArticle(_ item: ProductionItem, rules: Ruleset) -> String {
        let name = of(item, rules: rules)
        let vowel = name.first.map { "AEIOU".contains($0.uppercased()) } ?? false
        return (vowel ? "an " : "a ") + name
    }
}

enum TileText {
    /// "Grassland hills, forest".
    static func name(_ tile: Tile) -> String {
        var text = "\(tile.terrain)".capitalized
        if tile.elevation != .flat { text += " \("\(tile.elevation)".lowercased())" }
        if tile.feature != .none { text += ", \("\(tile.feature)".lowercased())" }
        if tile.riverEdges != 0 { text += ", river" }
        return text
    }
}

/// "1 turn", "3 turns".
func turnsText(_ n: Int) -> String { n == 1 ? "1 turn" : "\(n) turns" }

// MARK: - Game over

/// Victory or defeat, with every player's score, and a way back to the start screen.
struct GameOverCard: View {
    let session: GameSession
    let outcome: GameOutcome
    var onNewGame: () -> Void

    var body: some View {
        let view = session.view
        let won = winner == session.viewer
        VStack(spacing: HUD.Space.m) {
            HStack(spacing: HUD.Space.s) {
                Image(systemName: won ? "laurel.leading" : "flag.slash")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(won ? HUD.gilt : HUD.danger)
                VStack(spacing: 2) {
                    Text(headline).font(HUD.title(.title2))
                    Text("Turn \(view.turn) · \(kindName)")
                        .font(HUD.body(.caption))
                        .foregroundStyle(HUD.inkSoft)
                }
                if won {
                    Image(systemName: "laurel.trailing")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(HUD.gilt)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            Text(detail)
                .font(HUD.body(.subheadline))
                .foregroundStyle(HUD.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: HUD.Space.xs) {
                ForEach(view.players.filter(\.isMajor).sorted { ($0.score, -$0.id.rawValue) > ($1.score, -$1.id.rawValue) }, id: \.id) { player in
                    HStack(spacing: HUD.Space.s) {
                        PlayerEmblem(player: player.id, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            // Every screen names civilisations alike, met or not: the players
                            // are no secret (the waiting pill names them too).
                            Text(session.civName(of: player.id))
                                .font(HUD.title(.subheadline))
                                .strikethrough(!player.isAlive)
                            if let note = note(for: player.id, alive: player.isAlive) {
                                Text(note).font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft)
                            }
                        }
                        Spacer(minLength: HUD.Space.s)
                        if player.id == winner {
                            Image(systemName: "crown.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(HUD.gilt)
                        }
                        Text("\(player.score)").font(HUD.numeric())
                    }
                    .frame(minHeight: 34)
                    .accessibilityElement(children: .combine)
                }
                Text(scoreRule(view.rules.constants.score))
                    .font(HUD.body(.caption2))
                    .foregroundStyle(HUD.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, HUD.Space.xs)
            }
            .padding(HUD.Space.m)
            .parchmentWell()
            Button(action: onNewGame) {
                Label("New Game", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(BronzeButtonStyle())
        }
        .hudCard(padding: HUD.Space.l, cornerRadius: HUD.Radius.large)
        .frame(maxWidth: 420)
    }

    private var winner: PlayerID? {
        if case let .victory(player, _) = outcome { return player }
        return nil
    }

    private var headline: String {
        switch outcome {
        case let .victory(player, _): player == session.viewer ? "Victory" : "\(session.civName(of: player)) Wins"
        case .defeat: "Defeat"
        }
    }

    private var kindName: String {
        switch outcome {
        case let .victory(_, kind):
            switch kind {
            case .domination: "Domination"
            case .lastStanding: "Last standing"
            case .score: "Score"
            }
        case .defeat: "Eliminated"
        }
    }

    private var detail: String {
        switch outcome {
        case let .victory(player, kind):
            let mine = player == session.viewer
            switch kind {
            case .domination: return mine ? "Every other capital has fallen to you." : "Every other capital has fallen to them."
            case .lastStanding: return mine ? "No rival civilisation remains." : "They alone remain."
            case .score: return "The ages have run their course; the highest score wins."
            }
        case .defeat: return "Your civilisation has fallen."
        }
    }

    private func scoreRule(_ score: ScoreRules) -> String {
        "Score: \(score.perCity) per city, \(score.perPopulation) per citizen, \(score.perTech) per tech, \(score.perBuilding) per building (the Palace aside)."
    }

    private func note(for player: PlayerID, alive: Bool) -> String? {
        var parts: [String] = []
        if player == session.viewer { parts.append("You") }
        if !alive { parts.append("fallen") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Small pieces

/// A value with an icon over a caption, for cards.
struct Stat: View {
    var systemImage: String
    var value: String
    var label: String
    var tint: Color = HUD.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: HUD.Space.xs) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text(value).font(HUD.numeric())
            }
            Text(label).font(HUD.body(.caption2)).foregroundStyle(HUD.inkSoft).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A yield icon and amount, inline.
struct YieldNumber: View {
    var kind: YieldChip.Kind
    var value: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: kind.systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(kind.tint)
            Text("\(value)").font(HUD.numeric(.caption))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(kind.name)")
    }
}

/// A one-line hint on a card.
struct Hint: View {
    var systemImage: String
    var text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(HUD.body(.caption))
            .foregroundStyle(HUD.inkSoft)
    }
}

/// The × in a card's corner (a 44 pt target).
struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HUD.inkSoft)
                .frame(width: HUD.touch, height: HUD.touch)
                .contentShape(Rectangle())
        }
        .padding(.vertical, -HUD.Space.m)
        .padding(.trailing, -HUD.Space.s)
        .accessibilityLabel("Close")
    }
}
