import CoreGraphics
import GameCore

/// Terrain palette (SPEC D11: placeholders through M2). Must stay readable: terrain,
/// ownership and threats distinguishable at every zoom. Player colors: `PlayerPalette.swift`.
enum Palette {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func terrain(_ terrain: Terrain) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch terrain {
        case .grassland: (0.49, 0.60, 0.35)
        case .plains: (0.71, 0.66, 0.45)
        case .desert: (0.89, 0.81, 0.56)
        case .tundra: (0.58, 0.61, 0.53)
        case .snow: (0.92, 0.94, 0.96)
        case .coast: (0.33, 0.58, 0.72)
        case .ocean: (0.16, 0.32, 0.52)
        case .lake: (0.30, 0.56, 0.76)
        }
    }

    static let grid = rgb(0, 0, 0, 0.16)
    static let hill = rgb(0, 0, 0, 0.22)
    static let mountain = rgb(0.45, 0.42, 0.40)
    static let mountainShade = rgb(0.33, 0.31, 0.30)
    static let snowCap = rgb(0.97, 0.97, 0.98)
    static let forest = rgb(0.17, 0.35, 0.17)
    static let jungle = rgb(0.09, 0.40, 0.20)
    static let marsh = rgb(0.22, 0.42, 0.48)
    static let oasisWater = rgb(0.25, 0.55, 0.80)
    static let reef = rgb(0.92, 0.56, 0.62)
    static let ice = rgb(0.93, 0.96, 0.98, 0.85)
    static let fog = rgb(0.05, 0.06, 0.08)
}
