// Stable hashing (M1 §12.7): FNV-1a 64 fed by a small `Encoder` over a value's synthesized
// encoding — keys, integers and strings, in encoding order. No JSON and no `hashValue`, so OS
// and Swift updates cannot change the result. `GameState.stateHash()` and
// `Ruleset.contentHash` use it.
//
// The byte stream: a tag byte opens each keyed container (0xF1), unkeyed container (0xF2) and
// super-encoder (0xF6); each unkeyed element is preceded by 0xF4; a key and a string are their
// UTF-8 length (8 bytes, little-endian) then their bytes; integers are their own width,
// little-endian; Bool is one byte; nil is 0xF5; Float and Double are their bit patterns.

enum StableHash {
    /// FNV-1a 64 of `value`'s encoding.
    static func of<T: Encodable>(_ value: T) -> UInt64 {
        let sink = HashSink()
        // The hashing encoder never throws; a value's own `encode(to:)` could, in theory.
        try? value.encode(to: HashingEncoder(sink: sink))
        return sink.hash
    }
}

/// The FNV-1a 64 state the containers feed.
final class HashSink {
    private(set) var hash: UInt64 = 0xCBF2_9CE4_8422_2325

    @inline(__always)
    func byte(_ b: UInt8) {
        hash = (hash ^ UInt64(b)) &* 0x0000_0100_0000_01B3
    }

    @inline(__always)
    func integer<T: FixedWidthInteger>(_ value: T) {
        let bits = UInt64(truncatingIfNeeded: value)
        for i in 0..<MemoryLayout<T>.size { byte(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
    }

    func string(_ s: String) {
        integer(UInt64(s.utf8.count))
        for b in s.utf8 { byte(b) }
    }

    enum Tag {
        static let keyed: UInt8 = 0xF1
        static let unkeyed: UInt8 = 0xF2
        static let element: UInt8 = 0xF4
        static let null: UInt8 = 0xF5
        static let superEncoder: UInt8 = 0xF6
    }
}

struct HashingEncoder: Encoder {
    let sink: HashSink
    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        sink.byte(HashSink.Tag.keyed)
        return KeyedEncodingContainer(KeyedHashingContainer<Key>(sink: sink))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        sink.byte(HashSink.Tag.unkeyed)
        return UnkeyedHashingContainer(sink: sink)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleValueHashingContainer(sink: sink)
    }
}

private struct KeyedHashingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let sink: HashSink
    var codingPath: [CodingKey] { [] }

    private func key(_ key: Key) { sink.string(key.stringValue) }

    mutating func encodeNil(forKey key: Key) { self.key(key); sink.byte(HashSink.Tag.null) }
    mutating func encode(_ value: Bool, forKey key: Key) { self.key(key); sink.byte(value ? 1 : 0) }
    mutating func encode(_ value: String, forKey key: Key) { self.key(key); sink.string(value) }
    mutating func encode(_ value: Double, forKey key: Key) { self.key(key); sink.integer(value.bitPattern) }
    mutating func encode(_ value: Float, forKey key: Key) { self.key(key); sink.integer(value.bitPattern) }
    mutating func encode(_ value: Int, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: Int8, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: Int16, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: Int32, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: Int64, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: UInt, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: UInt8, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: UInt16, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: UInt32, forKey key: Key) { self.key(key); sink.integer(value) }
    mutating func encode(_ value: UInt64, forKey key: Key) { self.key(key); sink.integer(value) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        self.key(key)
        try value.encode(to: HashingEncoder(sink: sink))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type,
                                                         forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        self.key(key)
        sink.byte(HashSink.Tag.keyed)
        return KeyedEncodingContainer(KeyedHashingContainer<NestedKey>(sink: sink))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        self.key(key)
        sink.byte(HashSink.Tag.unkeyed)
        return UnkeyedHashingContainer(sink: sink)
    }

    mutating func superEncoder() -> Encoder {
        sink.byte(HashSink.Tag.superEncoder)
        return HashingEncoder(sink: sink)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        self.key(key)
        sink.byte(HashSink.Tag.superEncoder)
        return HashingEncoder(sink: sink)
    }
}

private struct UnkeyedHashingContainer: UnkeyedEncodingContainer {
    let sink: HashSink
    var codingPath: [CodingKey] { [] }
    private(set) var count = 0

    init(sink: HashSink) { self.sink = sink }

    private mutating func element() {
        sink.byte(HashSink.Tag.element)
        count += 1
    }

    mutating func encodeNil() { element(); sink.byte(HashSink.Tag.null) }
    mutating func encode(_ value: Bool) { element(); sink.byte(value ? 1 : 0) }
    mutating func encode(_ value: String) { element(); sink.string(value) }
    mutating func encode(_ value: Double) { element(); sink.integer(value.bitPattern) }
    mutating func encode(_ value: Float) { element(); sink.integer(value.bitPattern) }
    mutating func encode(_ value: Int) { element(); sink.integer(value) }
    mutating func encode(_ value: Int8) { element(); sink.integer(value) }
    mutating func encode(_ value: Int16) { element(); sink.integer(value) }
    mutating func encode(_ value: Int32) { element(); sink.integer(value) }
    mutating func encode(_ value: Int64) { element(); sink.integer(value) }
    mutating func encode(_ value: UInt) { element(); sink.integer(value) }
    mutating func encode(_ value: UInt8) { element(); sink.integer(value) }
    mutating func encode(_ value: UInt16) { element(); sink.integer(value) }
    mutating func encode(_ value: UInt32) { element(); sink.integer(value) }
    mutating func encode(_ value: UInt64) { element(); sink.integer(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        element()
        try value.encode(to: HashingEncoder(sink: sink))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        element()
        sink.byte(HashSink.Tag.keyed)
        return KeyedEncodingContainer(KeyedHashingContainer<NestedKey>(sink: sink))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        element()
        sink.byte(HashSink.Tag.unkeyed)
        return UnkeyedHashingContainer(sink: sink)
    }

    mutating func superEncoder() -> Encoder {
        element()
        sink.byte(HashSink.Tag.superEncoder)
        return HashingEncoder(sink: sink)
    }
}

private struct SingleValueHashingContainer: SingleValueEncodingContainer {
    let sink: HashSink
    var codingPath: [CodingKey] { [] }

    mutating func encodeNil() { sink.byte(HashSink.Tag.null) }
    mutating func encode(_ value: Bool) { sink.byte(value ? 1 : 0) }
    mutating func encode(_ value: String) { sink.string(value) }
    mutating func encode(_ value: Double) { sink.integer(value.bitPattern) }
    mutating func encode(_ value: Float) { sink.integer(value.bitPattern) }
    mutating func encode(_ value: Int) { sink.integer(value) }
    mutating func encode(_ value: Int8) { sink.integer(value) }
    mutating func encode(_ value: Int16) { sink.integer(value) }
    mutating func encode(_ value: Int32) { sink.integer(value) }
    mutating func encode(_ value: Int64) { sink.integer(value) }
    mutating func encode(_ value: UInt) { sink.integer(value) }
    mutating func encode(_ value: UInt8) { sink.integer(value) }
    mutating func encode(_ value: UInt16) { sink.integer(value) }
    mutating func encode(_ value: UInt32) { sink.integer(value) }
    mutating func encode(_ value: UInt64) { sink.integer(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: HashingEncoder(sink: sink))
    }
}
