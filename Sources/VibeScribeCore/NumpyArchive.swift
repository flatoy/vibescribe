import Accelerate
import Compression
import Foundation

enum NumpyArchiveError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "The speech model's weights could not be read (\(detail))."
        }
    }
}

/// A numpy array converted to `Float`, in row-major order.
struct NumpyArray {
    let shape: [Int]
    let values: [Float]
}

/// Reads the arrays in a `.npz` file: a zip of `.npy` files, stored or deflated.
struct NumpyArchive {
    private let members: [String: Data]

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var members: [String: Data] = [:]
        // The central directory has the real sizes; numpy leaves zip64 placeholders in the local headers.
        guard let end = Self.lastOffset(of: 0x0605_4B50, in: data) else {
            throw NumpyArchiveError.unreadable("no zip directory")
        }
        let count = Int(data.uint16(at: end + 10))
        var entry = Int(data.uint32(at: end + 16))
        for _ in 0..<count {
            guard entry + 46 <= data.count, data.uint32(at: entry) == 0x0201_4B50 else {
                throw NumpyArchiveError.unreadable("bad zip directory")
            }
            let method = data.uint16(at: entry + 10)
            let compressedSize = Int(data.uint32(at: entry + 20))
            let size = Int(data.uint32(at: entry + 24))
            let nameLength = Int(data.uint16(at: entry + 28))
            let extraLength = Int(data.uint16(at: entry + 30))
            let commentLength = Int(data.uint16(at: entry + 32))
            let header = Int(data.uint32(at: entry + 42))
            let name = String(decoding: data[data.startIndex + entry + 46 ..< data.startIndex + entry + 46 + nameLength], as: UTF8.self)
            entry += 46 + nameLength + extraLength + commentLength

            guard header + 30 <= data.count, data.uint32(at: header) == 0x0403_4B50 else {
                throw NumpyArchiveError.unreadable("bad zip entry \(name)")
            }
            let start = header + 30 + Int(data.uint16(at: header + 26)) + Int(data.uint16(at: header + 28))
            guard start + compressedSize <= data.count else { throw NumpyArchiveError.unreadable("truncated \(name)") }
            let stored = data[data.startIndex + start ..< data.startIndex + start + compressedSize]
            let contents: Data
            switch method {
            case 0: contents = Data(stored)
            case 8: contents = try Self.inflate(stored, size: size, name: name)
            default: throw NumpyArchiveError.unreadable("unsupported compression in \(name)")
            }
            members[name.hasSuffix(".npy") ? String(name.dropLast(4)) : name] = contents
        }
        self.members = members
    }

    func contains(_ name: String) -> Bool { members[name] != nil }

    func array(_ name: String) throws -> NumpyArray {
        guard let data = members[name] else { throw NumpyArchiveError.unreadable("missing \(name)") }
        return try Self.parse(data, name: name)
    }

    private static func parse(_ data: Data, name: String) throws -> NumpyArray {
        guard data.count > 10, data.prefix(6) == Data([0x93] + Array("NUMPY".utf8)) else {
            throw NumpyArchiveError.unreadable("\(name) is not an npy file")
        }
        let major = data[data.startIndex + 6]
        let headerLength = major == 1 ? Int(data.uint16(at: 8)) : Int(data.uint32(at: 8))
        let headerStart = major == 1 ? 10 : 12
        guard headerStart + headerLength <= data.count else { throw NumpyArchiveError.unreadable("\(name) header") }
        let header = String(decoding: data[data.startIndex + headerStart ..< data.startIndex + headerStart + headerLength], as: UTF8.self)
        guard !header.contains("'fortran_order': True"),
              let descr = header.firstMatch(of: /'descr': '([^']+)'/)?.1,
              let shapeText = header.firstMatch(of: /'shape': \(([^)]*)\)/)?.1 else {
            throw NumpyArchiveError.unreadable("\(name) header")
        }
        let shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let count = shape.reduce(1, *)
        let body = data[data.startIndex + headerStart + headerLength ..< data.endIndex]
        var values = [Float](repeating: 0, count: count)
        switch descr {
        case "<f4":
            guard body.count >= count * 4 else { throw NumpyArchiveError.unreadable("\(name) is truncated") }
            values.withUnsafeMutableBytes { _ = body.copyBytes(to: $0, count: count * 4) }
        case "<f2":
            guard body.count >= count * 2 else { throw NumpyArchiveError.unreadable("\(name) is truncated") }
            var halves = [UInt16](repeating: 0, count: count)
            halves.withUnsafeMutableBytes { _ = body.copyBytes(to: $0, count: count * 2) }
            Half.toFloat(halves, into: &values)
        case "|i1":
            guard body.count >= count else { throw NumpyArchiveError.unreadable("\(name) is truncated") }
            let bytes = [Int8](unsafeUninitializedCapacity: count) { buffer, initialized in
                initialized = body.copyBytes(to: UnsafeMutableRawBufferPointer(buffer), count: count)
            }
            vDSP.convertElements(of: bytes, to: &values)
        default:
            throw NumpyArchiveError.unreadable("\(name) has unsupported type \(descr)")
        }
        return NumpyArray(shape: shape, values: values)
    }

    private static func inflate(_ stored: Data, size: Int, name: String) throws -> Data {
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            stored.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, stored.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw NumpyArchiveError.unreadable("\(name) did not decompress") }
        return output
    }

    private static func lastOffset(of signature: UInt32, in data: Data) -> Int? {
        var offset = data.count - 22
        let earliest = max(0, data.count - 22 - 65_535)
        while offset >= earliest {
            if data.uint32(at: offset) == signature { return offset }
            offset -= 1
        }
        return nil
    }
}

/// Half-precision conversions without Swift's `Float16`, which Intel Macs lack.
enum Half {
    static func toFloat(_ halves: [UInt16], into values: inout [Float]) {
        halves.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { destination in
                toFloat(source.baseAddress!, destination.baseAddress!, count: source.count)
            }
        }
    }

    static func toFloat(_ source: UnsafePointer<UInt16>, _ destination: UnsafeMutablePointer<Float>, count: Int) {
        var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        var output = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&input, &output, 0)
    }

    static func fromFloat(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<UInt16>, count: Int) {
        var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        var output = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        vImageConvert_PlanarFtoPlanar16F(&input, &output, 0)
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
