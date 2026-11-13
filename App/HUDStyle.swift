import CoreText
import GameCore
import MapRendering
import SwiftUI
import UIKit

// The HUD's design system, matching the painted map (docs/ART.md): warm parchment panels with
// a soft warm-dark outline, serif type in brown-black ink, bronze for the main action, and
// shadows falling to the lower right under the upper-left sun. Player colours (`Heraldry`)
// appear only where something belongs to a player; yields have their own calm tints. Every
// control is at least 44 pt.
//
// Pieces:
// - tokens: `HUD` colours (also as UIKit colours in `HUD.UI`, for what Core Graphics draws over
//   the map: city banners, damage numbers), `HUD.Space`, `HUD.Radius`, the type scale (serif,
//   Dynamic Type; `HUD.UI.serif` for map labels), health colours;
// - materials: `parchment`, `parchmentCapsule`, `hudCard`, `parchmentWell`;
// - chips: `HUDChip`, `YieldChip`, `KindBadge`, `StatPill`;
// - meters: `HealthBar` (with the damage a fight may cost), `ProgressBar`;
// - buttons: `BronzeButtonStyle` (primary), `ParchmentButtonStyle` (secondary),
//   `ActionTileStyle` (unit actions), `ChipButtonStyle` (tappable chips), `RoundelLabel`;
// - small views: `CardHeader`, `Toast`, `WaitingPill`, `SectionHeader`, `PlayerEmblem`.

enum HUD {
    /// The palette as UIKit colours: the single source for the SwiftUI tokens below and for
    /// the text Core Graphics draws over the map.
    enum UI {
        static let ink = UIColor(red: 0.20, green: 0.14, blue: 0.10, alpha: 1)
        static let parchmentTop = UIColor(red: 0.97, green: 0.92, blue: 0.81, alpha: 1)
        static let parchmentBottom = UIColor(red: 0.91, green: 0.84, blue: 0.70, alpha: 1)
        static let parchmentWell = UIColor(red: 0.86, green: 0.78, blue: 0.63, alpha: 1)
        static let cream = UIColor(red: 1.00, green: 0.96, blue: 0.86, alpha: 1)
        static let bronzeTop = UIColor(red: 0.90, green: 0.72, blue: 0.40, alpha: 1)
        static let bronzeBottom = UIColor(red: 0.70, green: 0.48, blue: 0.22, alpha: 1)
        static let gilt = UIColor(red: 0.86, green: 0.64, blue: 0.20, alpha: 1)
        static let danger = UIColor(red: 0.62, green: 0.17, blue: 0.12, alpha: 1)
        /// Damage numbers on the viewer's own units and cities: a warmer, lighter crimson that
        /// reads on the map.
        static let wound = UIColor(red: 0.86, green: 0.24, blue: 0.16, alpha: 1)
        static let good = UIColor(red: 0.24, green: 0.45, blue: 0.20, alpha: 1)
        static let amber = UIColor(red: 0.85, green: 0.58, blue: 0.13, alpha: 1)
        static let healthy = UIColor(red: 0.36, green: 0.62, blue: 0.24, alpha: 1)
        static let food = UIColor(red: 0.33, green: 0.52, blue: 0.17, alpha: 1)
        static let production = UIColor(red: 0.60, green: 0.36, blue: 0.15, alpha: 1)
        static let gold = UIColor(red: 0.76, green: 0.55, blue: 0.08, alpha: 1)
        static let science = UIColor(red: 0.19, green: 0.42, blue: 0.66, alpha: 1)
        static let culture = UIColor(red: 0.52, green: 0.27, blue: 0.60, alpha: 1)

        /// The HUD's serif at a fixed size (map labels do not follow Dynamic Type: they scale
        /// with the map, not the text setting).
        static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
            return UIFont(descriptor: serif, size: size)
        }

        /// Serif numerals that keep their width as they change.
        static func numeric(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
            let font = serif(size, weight: weight)
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]],
            ])
            return UIFont(descriptor: descriptor, size: size)
        }

        /// Health from full (green) through amber to red.
        static func health(_ fraction: Double) -> UIColor {
            fraction > 0.6 ? healthy : (fraction > 0.3 ? amber : wound)
        }
    }

    // MARK: Colours

    static let ink = Color(uiColor: UI.ink)
    static let inkSoft = Color(uiColor: UI.ink).opacity(0.68)
    static let inkFaint = Color(uiColor: UI.ink).opacity(0.35)
    static let parchmentTop = Color(uiColor: UI.parchmentTop)
    static let parchmentBottom = Color(uiColor: UI.parchmentBottom)
    /// A recessed field inside a panel (rows, wells, text fields).
    static let parchmentWell = Color(uiColor: UI.parchmentWell).opacity(0.55)
    static let bronzeTop = Color(uiColor: UI.bronzeTop)
    static let bronzeBottom = Color(uiColor: UI.bronzeBottom)
    /// A gilt accent: the capital's star, a selected banner's rim.
    static let gilt = Color(uiColor: UI.gilt)
    /// Irreversible or hostile things: Disband, Raze, war, damage.
    static let danger = Color(uiColor: UI.danger)
    static let good = Color(uiColor: UI.good)
    static let amber = Color(uiColor: UI.amber)
    /// The deep sea behind the start screen, darkening toward the edges like a lamp-lit table.
    static let seaLight = Color(red: 0.13, green: 0.30, blue: 0.42)
    static let seaDark = Color(red: 0.04, green: 0.11, blue: 0.19)

    /// Yield tints: icons and numbers only, never panel fills.
    enum Yield {
        static let food = Color(uiColor: UI.food)
        static let production = Color(uiColor: UI.production)
        static let gold = Color(uiColor: UI.gold)
        static let science = Color(uiColor: UI.science)
        static let culture = Color(uiColor: UI.culture)
    }

    /// The player's banner colour (ownership only).
    static func color(of player: PlayerID) -> Color {
        Color(cgColor: Heraldry.color(player))
    }

    /// Health from full (green) through amber to red.
    static func health(_ fraction: Double) -> Color {
        Color(uiColor: UI.health(fraction))
    }

    // MARK: Layout

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    /// The smallest touch target.
    static let touch: CGFloat = 44

    /// The widest a bottom card grows on a wide screen.
    static let cardWidth: CGFloat = 460

    // MARK: Type (serif, Dynamic Type)

    /// The start screen's title.
    static func display() -> Font { .system(.largeTitle, design: .serif).weight(.bold) }
    static func title(_ style: Font.TextStyle = .headline) -> Font { .system(style, design: .serif).weight(.bold) }
    static func body(_ style: Font.TextStyle = .subheadline) -> Font { .system(style, design: .serif) }
    static func caption() -> Font { .system(.caption, design: .serif) }
    /// Numbers that change in place (yields, HP, turns).
    static func numeric(_ style: Font.TextStyle = .subheadline) -> Font {
        .system(style, design: .serif).weight(.semibold).monospacedDigit()
    }
    /// Small capitals over a section.
    static func label() -> Font { .system(.caption2, design: .serif).weight(.bold) }
    /// An icon beside text of a text style (SF Symbols scale with it).
    static func icon(_ style: Font.TextStyle = .subheadline) -> Font { .system(style).weight(.semibold) }
}

// MARK: - Materials

/// A parchment card: gradient fill, a light inner rim, a warm-dark outline and a sun shadow.
struct ParchmentPanel<S: InsettableShape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        content
            .foregroundStyle(HUD.ink)
            .background {
                shape
                    .fill(LinearGradient(colors: [HUD.parchmentTop, HUD.parchmentBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(shape.inset(by: 1.5).stroke(.white.opacity(0.45), lineWidth: 1))
                    .overlay(shape.stroke(HUD.ink.opacity(0.72), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.28), radius: 5, x: 2, y: 3)
            }
    }
}

extension View {
    func parchment(cornerRadius: CGFloat = HUD.Radius.medium) -> some View {
        modifier(ParchmentPanel(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func parchmentCapsule() -> some View {
        modifier(ParchmentPanel(shape: Capsule()))
    }

    /// A parchment card with the standard inner padding.
    func hudCard(padding: CGFloat = HUD.Space.m, cornerRadius: CGFloat = HUD.Radius.medium) -> some View {
        self.padding(.horizontal, padding + 2)
            .padding(.vertical, padding)
            .parchment(cornerRadius: cornerRadius)
    }

    /// A recessed well inside a card.
    func parchmentWell(cornerRadius: CGFloat = HUD.Radius.small) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(HUD.parchmentWell))
    }
}

// MARK: - Chips

/// A compact value with an icon: a top-bar statistic, a tag on a card.
struct HUDChip: View {
    var systemImage: String
    var text: String
    var tint: Color = HUD.ink
    var detail: String?

    var body: some View {
        HStack(spacing: HUD.Space.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(text).font(HUD.numeric())
            if let detail {
                Text(detail)
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, HUD.Space.m)
        .frame(minHeight: HUD.touch)
        .parchmentCapsule()
    }
}

/// A yield total with its per-turn change: "12  +3".
struct YieldChip: View {
    enum Kind {
        case gold, science, culture, food, production

        var systemImage: String {
            switch self {
            case .gold: "circle.circle.fill"
            case .science: "flask.fill"
            case .culture: "theatermasks.fill"
            case .food: "leaf.fill"
            case .production: "hammer.fill"
            }
        }

        var tint: Color {
            switch self {
            case .gold: HUD.Yield.gold
            case .science: HUD.Yield.science
            case .culture: HUD.Yield.culture
            case .food: HUD.Yield.food
            case .production: HUD.Yield.production
            }
        }

        var uiTint: UIColor {
            switch self {
            case .gold: HUD.UI.gold
            case .science: HUD.UI.science
            case .culture: HUD.UI.culture
            case .food: HUD.UI.food
            case .production: HUD.UI.production
            }
        }

        var name: String {
            switch self {
            case .gold: "Gold"
            case .science: "Science"
            case .culture: "Culture"
            case .food: "Food"
            case .production: "Production"
            }
        }
    }

    var kind: Kind
    /// The stock (gold in the treasury), or nil for flows shown only per turn.
    var total: Int?
    var perTurn: Int
    var detail: String?

    var body: some View {
        HStack(spacing: HUD.Space.xs) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.tint)
            // Numbers never break: they scale down a little first.
            if let total { Text("\(total)").font(HUD.numeric()).lineLimit(1).minimumScaleFactor(0.7) }
            Text(Self.signed(perTurn))
                .font(HUD.numeric(total == nil ? .subheadline : .caption))
                .foregroundStyle(perTurn < 0 ? HUD.danger : (total == nil ? HUD.ink : HUD.inkSoft))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(HUD.body(.caption))
                    .foregroundStyle(HUD.inkSoft)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, HUD.Space.m)
        .frame(minHeight: HUD.touch)
        .parchmentCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.name) \(total.map { "\($0), " } ?? "")\(Self.signed(perTurn)) per turn\(detail.map { ", \($0)" } ?? "")")
    }

    static func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "−\(-n)" }
}

/// A small tag on a row ("Auto", "Resume").
struct KindBadge: View {
    var text: String
    var tint: Color = HUD.inkSoft

    var body: some View {
        Text(text.uppercased())
            .font(HUD.label())
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
            .fixedSize()
    }
}

/// An inline statistic: an icon and a value, with the name for VoiceOver ("♥ 72").
struct StatPill: View {
    var systemImage: String
    var value: String
    var name: String
    var tint: Color = HUD.ink
    var valueTint: Color = HUD.ink

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(value).font(HUD.numeric(.footnote)).foregroundStyle(valueTint)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(value)")
    }
}

/// A heading inside a card.
struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title.uppercased())
            .font(HUD.label())
            .tracking(1.2)
            .foregroundStyle(HUD.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A player's emblem on a disc of their colour (ownership: banners, the waiting pill).
struct PlayerEmblem: View {
    var player: PlayerID
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(HUD.color(of: player))
            Circle().stroke(HUD.ink.opacity(0.75), lineWidth: 1.2)
            if let image = Heraldry.emblemImage(player, size: size * 0.72) {
                Image(decorative: image, scale: 3)
                    .resizable()
                    .frame(width: size * 0.72, height: size * 0.72)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Meters

/// A health bar in the map's style (ART.md §13): an ink edge, a dark well and a fill from green
/// through amber to red. With `after`, the part a fight may cost is paler, so a combat preview
/// reads at a glance.
struct HealthBar: View {
    /// Health now, 0...1.
    var fraction: Double
    /// Expected health after the fight, 0...1.
    var after: Double?
    var height: CGFloat = 6

    var body: some View {
        let now = min(max(fraction, 0), 1)
        let then = min(max(after ?? now, 0), now)
        let tint = HUD.health(then)
        Capsule()
            .fill(HUD.ink.opacity(0.5))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let w = geometry.size.width
                    ZStack(alignment: .leading) {
                        if then < now {
                            Capsule().fill(HUD.health(now).opacity(0.38)).frame(width: max(height, w * now))
                        }
                        if then > 0 {
                            Capsule().fill(tint).frame(width: max(height, w * then))
                        }
                    }
                }
                .padding(1)
            }
            .overlay(Capsule().stroke(HUD.ink.opacity(0.8), lineWidth: 1))
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Progress toward something (research, production): a thin bar in a yield's tint.
struct ProgressBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 5

    var body: some View {
        Capsule()
            .fill(HUD.ink.opacity(0.18))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The main action (Next / End Turn, Start): a bronze capsule with an ink outline that sinks a
/// little when pressed.
struct BronzeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HUD.title(.headline))
            .foregroundStyle(HUD.ink.opacity(isEnabled ? 1 : 0.55))
            .padding(.horizontal, 22)
            .frame(minHeight: 48)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: isEnabled ? [HUD.bronzeTop, HUD.bronzeBottom] : [HUD.parchmentTop, HUD.parchmentBottom],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().inset(by: 2).stroke(.white.opacity(configuration.isPressed ? 0.2 : 0.5), lineWidth: 1))
                    .overlay(Capsule().stroke(HUD.ink.opacity(isEnabled ? 0.8 : 0.45), lineWidth: 1.5))
                    .shadow(color: .black.opacity(configuration.isPressed ? 0.15 : 0.3),
                            radius: configuration.isPressed ? 2 : 5, x: 2, y: configuration.isPressed ? 1 : 3)
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .contentShape(Capsule())
    }
}

/// A secondary action: a parchment capsule.
struct ParchmentButtonStyle: ButtonStyle {
    var role: ButtonRole?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HUD.title(.subheadline))
            .foregroundStyle((role == .destructive ? HUD.danger : HUD.ink).opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, HUD.Space.l)
            .frame(minHeight: HUD.touch)
            .parchmentCapsule()
            .brightness(configuration.isPressed ? -0.05 : 0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .contentShape(Capsule())
    }
}

/// A unit action: an icon over a short label on a parchment tile. `available` false dims it
/// (it stays tappable, to say why not); `compact` makes it shorter for a phone on its side.
struct ActionTileStyle: ButtonStyle {
    var role: ButtonRole?
    var available = true
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .actionTile(pressed: configuration.isPressed, lit: isEnabled && available, destructive: role == .destructive,
                        compact: compact)
    }
}

extension View {
    /// The look of a unit action tile (for a label with an icon and a title). `fill`: the tile
    /// takes its share of a row that fits them all (so it may start narrower: a phone's six
    /// tiles fit its card rather than scroll).
    func actionTile(pressed: Bool, lit: Bool, destructive: Bool = false, compact: Bool = false, fill: Bool = false) -> some View {
        labelStyle(ActionTileLabelStyle(compact: compact))
            .foregroundStyle((destructive ? HUD.danger : HUD.ink).opacity(lit ? 1 : 0.36))
            .frame(minWidth: fill ? (compact ? 40 : 44) : (compact ? 54 : 60), maxWidth: fill ? .infinity : nil,
                   minHeight: compact ? HUD.touch : 52)
            .padding(.horizontal, HUD.Space.xs)
            .background {
                RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
                    .fill(pressed ? HUD.parchmentWell.opacity(1.6) : HUD.parchmentWell.opacity(lit ? 1 : 0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: HUD.Radius.small, style: .continuous)
                    .stroke(HUD.ink.opacity(lit ? 0.35 : 0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: HUD.Radius.small))
            .offset(y: pressed ? 1 : 0)
    }
}

/// How far the action bar squeezes its tiles before it scrolls (`FillRow`): to `minFit` of
/// their own widths, their titles shrinking (to `minScale` at most) to fit.
enum ActionTile {
    static let minScale: CGFloat = 0.75
    static let minFit: CGFloat = 0.8
}

private struct ActionTileLabelStyle: LabelStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: compact ? 1 : 3) {
            configuration.icon.font(.system(size: compact ? 15 : 17, weight: .semibold))
            // Scales down a little in a row just too wide for its tiles (the action bar shrinks
            // them before it scrolls).
            configuration.title.font(HUD.body(.caption2).weight(.semibold)).lineLimit(1).minimumScaleFactor(ActionTile.minScale)
        }
    }
}

/// A tappable chip (the top bar's yields): it dims and sinks a little when pressed.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.05 : 0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .contentShape(Capsule())
    }
}

/// A round parchment button holding an icon (the game menu).
struct RoundelLabel: View {
    var systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: HUD.touch, height: HUD.touch)
            .modifier(ParchmentPanel(shape: Circle()))
    }
}

// MARK: - Small views

/// A card's first row: whose it is (emblem) or what it is (icon), the title, badges, and the
/// × that closes it.
struct CardHeader<Badges: View>: View {
    var title: String
    var player: PlayerID?
    var systemImage: String?
    var onClose: (() -> Void)?
    @ViewBuilder var badges: () -> Badges
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: HUD.Space.s) {
            if let player {
                PlayerEmblem(player: player, size: 24)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)).foregroundStyle(HUD.inkSoft)
                    .frame(width: 24, height: 24)
            }
            // One line; two at the accessibility text sizes, where one would cut the title short.
            Text(title).font(HUD.title(.headline)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                .accessibilityAddTraits(.isHeader)
            badges()
            Spacer(minLength: 0)
            if let onClose { CloseButton(action: onClose) }
        }
    }
}

extension CardHeader where Badges == EmptyView {
    init(title: String, player: PlayerID? = nil, systemImage: String? = nil, onClose: (() -> Void)? = nil) {
        self.init(title: title, player: player, systemImage: systemImage, onClose: onClose) { EmptyView() }
    }
}

/// A card's buttons side by side, stacked at the accessibility text sizes, where side by side
/// their labels would break mid-word ("Diplo-macy").
struct CardButtonRow<Content: View>: View {
    var spacing: CGFloat = HUD.Space.s
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        layout { content() }
    }
}

/// A transient message over the map.
struct Toast: View {
    var text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: HUD.Space.s) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(HUD.inkSoft) }
            Text(text).font(HUD.body(.callout).weight(.semibold))
        }
        .padding(.horizontal, HUD.Space.l)
        .padding(.vertical, HUD.Space.s)
        .parchmentCapsule()
        .accessibilityElement(children: .combine)
    }
}

/// Shown while another player's phase plays: "Waiting for Mongols".
struct WaitingPill: View {
    var player: PlayerID
    var civName: String

    var body: some View {
        HStack(spacing: HUD.Space.s) {
            PlayerEmblem(player: player, size: 24)
            Text("Waiting for \(civName)").font(HUD.title(.subheadline))
            ProgressView().controlSize(.small).tint(HUD.inkSoft)
        }
        .padding(.leading, HUD.Space.s)
        .padding(.trailing, HUD.Space.m)
        .frame(minHeight: HUD.touch)
        .parchmentCapsule()
        .accessibilityElement(children: .combine)
    }
}
