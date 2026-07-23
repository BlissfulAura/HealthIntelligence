//
//  MinimalZip.swift
//  HealthIntelligence
//
//  A minimal, dependency-free ZIP reader: just enough of the format
//  (End of Central Directory -> Central Directory -> Local File Header)
//  to list and extract entries from a standard ZIP archive, which is what
//  Garmin's account data export produces. No third-party library needed —
//  iOS has no public unzip API in Foundation, but Apple's Compression
//  framework's `COMPRESSION_ZLIB` algorithm implements raw DEFLATE
//  (RFC 1951, no zlib header/trailer), which is exactly the format ZIP's
//  "deflate" compression method (8) uses. "Stored" entries (method 0, no
//  compression) are just copied through.
//
//  Deliberately does not support ZIP64 (needed only for >4GB archives/
//  entries or >65535 entries) or encrypted archives — neither applies to a
//  personal Garmin data export.
//

import Compression
import Foundation

enum MinimalZipError: LocalizedError {
    case notAZipFile
    case corruptArchive(String)
    case unsupportedCompressionMethod(UInt16)
    case decompressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAZipFile:
            "This file doesn't look like a ZIP archive."
        case .corruptArchive(let detail):
            "The ZIP archive appears corrupt (\(detail))."
        case .unsupportedCompressionMethod(let method):
            "Unsupported ZIP compression method (\(method))."
        case .decompressionFailed(let path):
            "Failed to decompress \(path)."
        }
    }
}

struct MinimalZip {
    struct Entry {
        let path: String
        let uncompressedSize: Int
        fileprivate let compressedSize: Int
        fileprivate let compressionMethod: UInt16
        fileprivate let localHeaderOffset: Int
    }

    let entries: [Entry]
    private let data: Data

    init(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        self.data = data
        self.entries = try Self.readCentralDirectory(from: data)
    }

    /// Reads and, if necessary, decompresses one entry's contents.
    func contents(of entry: Entry) throws -> Data {
        guard data.readUInt32(at: entry.localHeaderOffset) == 0x0403_4b50 else {
            throw MinimalZipError.corruptArchive("bad local file header for \(entry.path)")
        }
        guard let nameLength = data.readUInt16(at: entry.localHeaderOffset + 26),
            let extraLength = data.readUInt16(at: entry.localHeaderOffset + 28) else {
            throw MinimalZipError.corruptArchive("truncated local file header for \(entry.path)")
        }

        let dataStart = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        guard dataStart + entry.compressedSize <= data.count else {
            throw MinimalZipError.corruptArchive("entry data out of bounds for \(entry.path)")
        }
        let compressed = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataStart + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, uncompressedSize: entry.uncompressedSize, path: entry.path)
        default:
            throw MinimalZipError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    // MARK: - Central directory parsing

    private static func readCentralDirectory(from data: Data) throws -> [Entry] {
        let eocdOffset = try findEndOfCentralDirectory(in: data)
        guard let totalEntries = data.readUInt16(at: eocdOffset + 10),
            let centralDirectoryOffset = data.readUInt32(at: eocdOffset + 16) else {
            throw MinimalZipError.corruptArchive("malformed end-of-central-directory record")
        }

        var entries: [Entry] = []
        var offset = Int(centralDirectoryOffset)

        for _ in 0..<Int(totalEntries) {
            guard data.readUInt32(at: offset) == 0x0201_4b50 else {
                throw MinimalZipError.corruptArchive("bad central directory signature")
            }
            guard let compressionMethod = data.readUInt16(at: offset + 10),
                let compressedSize = data.readUInt32(at: offset + 20),
                let uncompressedSize = data.readUInt32(at: offset + 24),
                let nameLength = data.readUInt16(at: offset + 28),
                let extraLength = data.readUInt16(at: offset + 30),
                let commentLength = data.readUInt16(at: offset + 32),
                let localHeaderOffset = data.readUInt32(at: offset + 42) else {
                throw MinimalZipError.corruptArchive("truncated central directory record")
            }

            let nameStart = offset + 46
            guard nameStart + Int(nameLength) <= data.count else {
                throw MinimalZipError.corruptArchive("truncated filename")
            }
            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + Int(nameLength)))
            let path = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            // Directory entries (trailing "/") carry no data of their own.
            if !path.hasSuffix("/") {
                entries.append(Entry(
                    path: path,
                    uncompressedSize: Int(uncompressedSize),
                    compressedSize: Int(compressedSize),
                    compressionMethod: compressionMethod,
                    localHeaderOffset: Int(localHeaderOffset)
                ))
            }

            offset = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let minimumSize = 22
        guard data.count >= minimumSize else { throw MinimalZipError.notAZipFile }

        // The EOCD's trailing comment field can be up to 65535 bytes, so the
        // signature isn't necessarily at a fixed offset from the end.
        let searchFloor = max(0, data.count - minimumSize - 65536)
        var offset = data.count - minimumSize
        while offset >= searchFloor {
            if data.readUInt32(at: offset) == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }
        throw MinimalZipError.notAZipFile
    }

    // MARK: - Decompression

    private static func inflate(_ compressed: Data, uncompressedSize: Int, path: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }

        var output = [UInt8](repeating: 0, count: uncompressedSize)
        let bytesWritten = output.withUnsafeMutableBytes { outputBuffer -> Int in
            compressed.withUnsafeBytes { inputBuffer -> Int in
                guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase, uncompressedSize,
                    inputBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard bytesWritten == uncompressedSize else {
            throw MinimalZipError.decompressionFailed(path)
        }
        return Data(output)
    }
}

// MARK: - Little-endian reads

private extension Data {
    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
