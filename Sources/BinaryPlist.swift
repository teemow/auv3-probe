import Foundation

// A self-contained Apple binary-property-list (bplist00) decoder. AUM's .aumproj
// and .aum_midimap files are bplists whose top level is an NSKeyedArchiver object
// graph; this lets the app read them on-device, with no daemon and no Foundation
// NSKeyedUnarchiver (which would need AUM's private classes registered).
//
// It mirrors the Go side's approach (internal/aum/archive.go, which leans on
// howett.net/plist): bplist references inside arrays/dicts are inlined, but
// NSKeyedArchiver's CF$UID values are kept as a distinct `.uid` case so the
// object graph can be resolved lazily (UIDs index the archive's $objects table
// and may form cycles, so they must never be inlined). See AUMSessionParser for
// the graph walk built on top of this.
//
// Format reference: CFBinaryPlist — an 8-byte "bplist00" header, the object
// table, an offset table, and a 32-byte trailer giving the int/ref widths,
// object count, root index and offset-table location.

/// A decoded binary-plist value. `.uid` is an NSKeyedArchiver reference into the
/// archive's object table; every other case is a concrete value.
indirect enum PlistValue {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case date(Double)
    case data([UInt8])
    case string(String)
    case uid(Int)
    case array([PlistValue])
    case dict([String: PlistValue])
}

enum BinaryPlistError: LocalizedError {
    case tooSmall
    case badMagic
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .tooSmall:
            return "file is too small to be a binary plist"
        case .badMagic:
            return "not a binary property list (.aumproj / .aum_midimap expected)"
        case .corrupt(let why):
            return "corrupt binary plist: \(why)"
        }
    }
}

struct BinaryPlistDecoder {
    private let bytes: [UInt8]
    private let offsetSize: Int
    private let refSize: Int
    private let topObject: Int
    private let offsetTable: [Int]

    /// Decode `data` and return its root object, with bplist references inlined
    /// and CF$UID values kept as `.uid`.
    static func decode(_ data: Data) throws -> PlistValue {
        let decoder = try BinaryPlistDecoder(data)
        return try decoder.object(at: decoder.topObject, depth: 0)
    }

    private init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 40 else { throw BinaryPlistError.tooSmall }
        guard bytes[0..<6].elementsEqual("bplist".utf8) else { throw BinaryPlistError.badMagic }
        self.bytes = bytes

        // The 32-byte trailer: [unused×5][sortVersion][offsetIntSize]
        // [objectRefSize][numObjects:8][topObject:8][offsetTableOffset:8].
        let trailer = bytes.count - 32
        offsetSize = Int(bytes[trailer + 6])
        refSize = Int(bytes[trailer + 7])
        let numObjects = Int(Self.readUInt(bytes, trailer + 8, 8))
        topObject = Int(Self.readUInt(bytes, trailer + 16, 8))
        let offsetTableOffset = Int(Self.readUInt(bytes, trailer + 24, 8))

        guard offsetSize >= 1, refSize >= 1, numObjects >= 0 else {
            throw BinaryPlistError.corrupt("bad trailer widths")
        }

        var table = [Int]()
        table.reserveCapacity(numObjects)
        for i in 0..<numObjects {
            let pos = offsetTableOffset + i * offsetSize
            guard pos + offsetSize <= bytes.count else {
                throw BinaryPlistError.corrupt("offset table out of range")
            }
            table.append(Int(Self.readUInt(bytes, pos, offsetSize)))
        }
        offsetTable = table
        guard topObject < table.count else {
            throw BinaryPlistError.corrupt("top object out of range")
        }
    }

    /// Parse the object at table index `index`. `depth` bounds runaway recursion
    /// (the bplist reference graph is acyclic, so real files stay shallow).
    private func object(at index: Int, depth: Int) throws -> PlistValue {
        guard depth < 2048 else { throw BinaryPlistError.corrupt("nesting too deep") }
        guard index >= 0, index < offsetTable.count else {
            throw BinaryPlistError.corrupt("object index out of range")
        }
        let p = offsetTable[index]
        guard p < bytes.count else { throw BinaryPlistError.corrupt("object offset out of range") }

        let marker = bytes[p]
        let hi = marker >> 4
        let lo = marker & 0x0F

        switch hi {
        case 0x0:
            switch lo {
            case 0x0: return .null
            case 0x8: return .bool(false)
            case 0x9: return .bool(true)
            default: return .null
            }
        case 0x1: // int: 2^lo bytes, big-endian (8-byte is signed)
            let count = 1 << Int(lo)
            try ensure(p + 1, count)
            let raw = Self.readUInt(bytes, p + 1, count)
            return count >= 8 ? .int(Int64(bitPattern: raw)) : .int(Int64(raw))
        case 0x2: // real: 4 or 8 bytes IEEE-754, big-endian
            let count = 1 << Int(lo)
            try ensure(p + 1, count)
            if count == 4 {
                return .real(Double(Float(bitPattern: UInt32(truncatingIfNeeded: Self.readUInt(bytes, p + 1, 4)))))
            }
            return .real(Double(bitPattern: Self.readUInt(bytes, p + 1, 8)))
        case 0x3: // date: 8-byte double, seconds since 2001
            try ensure(p + 1, 8)
            return .date(Double(bitPattern: Self.readUInt(bytes, p + 1, 8)))
        case 0x4: // data
            let (count, start) = try length(p, lo)
            try ensure(start, count)
            return .data(Array(bytes[start..<start + count]))
        case 0x5: // ASCII string
            let (count, start) = try length(p, lo)
            try ensure(start, count)
            return .string(String(decoding: bytes[start..<start + count], as: UTF8.self))
        case 0x6: // UTF-16BE string (count = code units)
            let (count, start) = try length(p, lo)
            try ensure(start, count * 2)
            var units = [UInt16]()
            units.reserveCapacity(count)
            for i in 0..<count {
                let high = UInt16(bytes[start + i * 2])
                let low = UInt16(bytes[start + i * 2 + 1])
                units.append((high << 8) | low)
            }
            return .string(String(decoding: units, as: UTF16.self))
        case 0x8: // UID: (lo + 1) bytes, big-endian
            let count = Int(lo) + 1
            try ensure(p + 1, count)
            return .uid(Int(Self.readUInt(bytes, p + 1, count)))
        case 0xA, 0xC: // array (0xA) / set (0xC): `count` refs
            let (count, start) = try length(p, lo)
            try ensure(start, count * refSize)
            var out = [PlistValue]()
            out.reserveCapacity(count)
            for i in 0..<count {
                let ref = Int(Self.readUInt(bytes, start + i * refSize, refSize))
                out.append(try object(at: ref, depth: depth + 1))
            }
            return .array(out)
        case 0xD: // dict: `count` key refs then `count` value refs
            let (count, start) = try length(p, lo)
            try ensure(start, count * refSize * 2)
            var out = [String: PlistValue]()
            out.reserveCapacity(count)
            for i in 0..<count {
                let keyRef = Int(Self.readUInt(bytes, start + i * refSize, refSize))
                let valRef = Int(Self.readUInt(bytes, start + (count + i) * refSize, refSize))
                if case .string(let key) = try object(at: keyRef, depth: depth + 1) {
                    out[key] = try object(at: valRef, depth: depth + 1)
                }
            }
            return .dict(out)
        default:
            throw BinaryPlistError.corrupt("unknown object marker 0x\(String(marker, radix: 16))")
        }
    }

    /// Resolve a collection's element count and the byte offset where its
    /// contents begin. A low nibble of 0xF means the count is an int object that
    /// follows the marker.
    private func length(_ p: Int, _ lo: UInt8) throws -> (count: Int, start: Int) {
        if lo != 0x0F { return (Int(lo), p + 1) }
        guard p + 1 < bytes.count, bytes[p + 1] >> 4 == 0x1 else {
            throw BinaryPlistError.corrupt("bad collection length marker")
        }
        let intCount = 1 << Int(bytes[p + 1] & 0x0F)
        try ensure(p + 2, intCount)
        let count = Int(Self.readUInt(bytes, p + 2, intCount))
        return (count, p + 2 + intCount)
    }

    private func ensure(_ start: Int, _ count: Int) throws {
        guard start >= 0, count >= 0, start + count <= bytes.count else {
            throw BinaryPlistError.corrupt("read past end of file")
        }
    }

    private static func readUInt(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count {
            value = (value << 8) | UInt64(bytes[start + i])
        }
        return value
    }
}
