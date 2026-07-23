//
//  MinimalZipTests.swift
//  HealthIntelligenceTests
//
//  Builds tiny real ZIP archives by hand (both "stored" and "deflate"
//  entries) and verifies MinimalZip reads them back correctly. There's no
//  Process/NSTask on iOS to shell out to a real `zip` binary, so these
//  fixtures are constructed directly from the ZIP format's local file
//  header / central directory / end-of-central-directory records. CRC32
//  fields are left as 0 throughout since MinimalZip doesn't validate them
//  (it trusts the sizes recorded in the central directory).
//

import Compression
import XCTest
@testable import HealthIntelligence

final class MinimalZipTests: XCTestCase {
    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }

    private func deflate(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: data.count + 128)
        let outputCapacity = output.count
        let compressedSize = data.withUnsafeBytes { inputBuffer -> Int in
            output.withUnsafeMutableBytes { outputBuffer -> Int in
                guard let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(outputBase, outputCapacity, inputBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return Data(output.prefix(compressedSize))
    }

    private func le16(_ value: Int) -> Data {
        let v = UInt16(value)
        return Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }

    private func le32(_ value: Int) -> Data {
        let v = UInt32(value)
        return Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private func makeZip(entries: [(path: String, content: Data, compress: Bool)]) -> Data {
        var body = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let method = entry.compress ? 8 : 0
            let storedContent = entry.compress ? deflate(entry.content) : entry.content
            let localHeaderOffset = body.count

            var localHeader = Data()
            localHeader.append(le32(0x0403_4b50))
            localHeader.append(le16(20)) // version needed
            localHeader.append(le16(0)) // flags
            localHeader.append(le16(method))
            localHeader.append(le16(0)) // mod time
            localHeader.append(le16(0)) // mod date
            localHeader.append(le32(0)) // crc32 (unchecked by MinimalZip)
            localHeader.append(le32(storedContent.count))
            localHeader.append(le32(entry.content.count))
            localHeader.append(le16(nameData.count))
            localHeader.append(le16(0)) // extra length
            localHeader.append(nameData)

            body.append(localHeader)
            body.append(storedContent)

            var centralEntry = Data()
            centralEntry.append(le32(0x0201_4b50))
            centralEntry.append(le16(20)) // version made by
            centralEntry.append(le16(20)) // version needed
            centralEntry.append(le16(0)) // flags
            centralEntry.append(le16(method))
            centralEntry.append(le16(0)) // mod time
            centralEntry.append(le16(0)) // mod date
            centralEntry.append(le32(0)) // crc32
            centralEntry.append(le32(storedContent.count))
            centralEntry.append(le32(entry.content.count))
            centralEntry.append(le16(nameData.count))
            centralEntry.append(le16(0)) // extra length
            centralEntry.append(le16(0)) // comment length
            centralEntry.append(le16(0)) // disk number start
            centralEntry.append(le16(0)) // internal attrs
            centralEntry.append(le32(0)) // external attrs
            centralEntry.append(le32(localHeaderOffset))
            centralEntry.append(nameData)

            centralDirectory.append(centralEntry)
        }

        let centralDirectoryOffset = body.count
        var archive = body
        archive.append(centralDirectory)

        var eocd = Data()
        eocd.append(le32(0x0605_4b50))
        eocd.append(le16(0)) // disk number
        eocd.append(le16(0)) // disk with central directory
        eocd.append(le16(entries.count)) // entries on this disk
        eocd.append(le16(entries.count)) // total entries
        eocd.append(le32(centralDirectory.count))
        eocd.append(le32(centralDirectoryOffset))
        eocd.append(le16(0)) // comment length
        archive.append(eocd)

        return archive
    }

    // MARK: - Tests

    func test_readsStoredEntry() throws {
        let content = Data("Hello, Garmin!".utf8)
        let zip = makeZip(entries: [(path: "hello.txt", content: content, compress: false)])
        let url = try writeTempFile(zip)

        let archive = try MinimalZip(fileURL: url)
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(archive.entries[0].path, "hello.txt")
        XCTAssertEqual(try archive.contents(of: archive.entries[0]), content)
    }

    func test_readsDeflatedEntry() throws {
        let content = Data(String(repeating: "Garmin wellness data. ", count: 200).utf8)
        let zip = makeZip(entries: [(path: "wellness/data.json", content: content, compress: true)])
        let url = try writeTempFile(zip)

        let archive = try MinimalZip(fileURL: url)
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(try archive.contents(of: archive.entries[0]), content)
    }

    func test_readsMultipleMixedEntries() throws {
        let first = Data("first entry, stored".utf8)
        let second = Data(String(repeating: "second entry, deflated. ", count: 100).utf8)
        let zip = makeZip(entries: [
            (path: "a/first.txt", content: first, compress: false),
            (path: "b/second.json", content: second, compress: true),
        ])
        let url = try writeTempFile(zip)

        let archive = try MinimalZip(fileURL: url)
        XCTAssertEqual(archive.entries.map(\.path), ["a/first.txt", "b/second.json"])
        XCTAssertEqual(try archive.contents(of: archive.entries[0]), first)
        XCTAssertEqual(try archive.contents(of: archive.entries[1]), second)
    }

    func test_skipsDirectoryEntries() throws {
        let content = Data("inside a folder".utf8)
        let zip = makeZip(entries: [
            (path: "folder/", content: Data(), compress: false),
            (path: "folder/file.txt", content: content, compress: false),
        ])
        let url = try writeTempFile(zip)

        let archive = try MinimalZip(fileURL: url)
        XCTAssertEqual(archive.entries.map(\.path), ["folder/file.txt"])
    }

    func test_throwsForNonZipData() throws {
        let url = try writeTempFile(Data("not a zip file at all".utf8))
        XCTAssertThrowsError(try MinimalZip(fileURL: url)) { error in
            XCTAssertTrue(error is MinimalZipError)
        }
    }
}
