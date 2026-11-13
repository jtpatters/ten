/// Compact per-tile boolean set (e.g., explored tiles for a player).
public struct TileBitSet: Codable, Hashable, Sendable {
    public private(set) var words: [UInt64]
    public let count: Int

    public init(count: Int) {
        self.count = count
        self.words = Array(repeating: 0, count: (count + 63) / 64)
    }

    public subscript(index: Int) -> Bool {
        get { words[index >> 6] & (1 << UInt64(index & 63)) != 0 }
        set {
            if newValue {
                words[index >> 6] |= 1 << UInt64(index & 63)
            } else {
                words[index >> 6] &= ~(1 << UInt64(index & 63))
            }
        }
    }

    public var setCount: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Whether no tile is in the set.
    public var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    /// Adds every tile of `other` (same count).
    public mutating func formUnion(_ other: TileBitSet) {
        precondition(other.count == count)
        for i in words.indices { words[i] |= other.words[i] }
    }

    /// The tiles in this set and not in `other` (same count).
    public func subtracting(_ other: TileBitSet) -> TileBitSet {
        precondition(other.count == count)
        var result = self
        for i in result.words.indices { result.words[i] &= ~other.words[i] }
        return result
    }

    /// Whether every tile of `other` is in this set.
    public func isSuperset(of other: TileBitSet) -> Bool {
        guard other.count == count else { return false }
        return words.indices.allSatisfy { other.words[$0] & ~words[$0] == 0 }
    }

    /// Calls `body` with each tile index in the set, in increasing order.
    public func forEachIndex(_ body: (Int) -> Void) {
        for (w, word) in words.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                body(w << 6 + bits.trailingZeroBitCount)
                bits &= bits - 1
            }
        }
    }

    /// The tile indices in the set, increasing.
    public var indices: [Int] {
        var result: [Int] = []
        forEachIndex { result.append($0) }
        return result
    }
}
