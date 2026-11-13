/// Deterministic RNG for all simulation randomness.
///
/// Never use `SystemRandomNumberGenerator`, and avoid stdlib helpers like
/// `Int.random(in:using:)` in sim code: their algorithms may change between
/// Swift releases, which would break save/replay determinism.
public struct SplitMix64: RandomNumberGenerator, Codable, Hashable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// Independent stream derived from a seed plus salts, e.g. (gameSeed, turn, attackerID).
    public init(seed: UInt64, salts: UInt64...) {
        var mixer = SplitMix64(seed: seed)
        for salt in salts {
            mixer = SplitMix64(seed: mixer.next() ^ salt)
        }
        state = mixer.next()
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Unbiased integer in `0..<bound` (Lemire's method).
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound > 0)
        let b = UInt64(bound)
        var m = next().multipliedFullWidth(by: b)
        if m.low < b {
            let threshold = (0 &- b) % b
            while m.low < threshold {
                m = next().multipliedFullWidth(by: b)
            }
        }
        return Int(m.high)
    }

    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + nextInt(below: range.count)
    }

    /// Uniform double in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    public mutating func chance(_ probability: Double) -> Bool {
        nextUnit() < probability
    }

    public mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[nextInt(below: items.count)]
    }
}
