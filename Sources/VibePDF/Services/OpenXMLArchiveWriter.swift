// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Writes the small, standards-compliant ZIP containers used by DOCX/PPTX.
///
/// Office page images are already PNG-compressed, so the archive deliberately
/// uses ZIP's `stored` method. This avoids a third-party compression dependency
/// and keeps conversion available in the App Sandbox and offline.
enum OpenXMLArchiveWriter {
    struct Entry {
        let path: String
        let data: Data
    }

    private struct CentralRecord {
        let pathData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    /// Streams already-compressed page images with a 256 KiB working buffer.
    /// Only the small XML parts and central directory remain in memory.
    static func write(
        _ entries: [Entry],
        files: [String: URL],
        to destination: URL
    ) throws {
        guard !entries.isEmpty, entries.count <= Int(UInt16.max),
              Set(entries.map(\.path)).count == entries.count else {
            throw WorkspaceError.operationFailed(L10n.string("conversion.error.package_too_large"))
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw WorkspaceError.cannotSave(destination)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var central = Data()
        var offset: UInt64 = 0
        func emit(_ data: Data) throws {
            guard offset + UInt64(data.count) <= UInt64(UInt32.max) else {
                throw WorkspaceError.operationFailed(L10n.string("conversion.error.package_too_large"))
            }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
        for entry in entries {
            try Task.checkCancellation()
            let path = Data(entry.path.utf8)
            guard !path.isEmpty, path.count <= Int(UInt16.max),
                  !entry.path.hasPrefix("/"), !entry.path.contains("..") else {
                throw WorkspaceError.operationFailed(L10n.string("conversion.error.package_invalid"))
            }
            let file = files[entry.path]
            let size: Int
            let checksum: UInt32
            if let file {
                size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                checksum = try CRC32.checksum(file: file)
            } else {
                size = entry.data.count
                checksum = CRC32.checksum(entry.data)
            }
            guard size >= 0, UInt64(size) <= UInt64(UInt32.max) else {
                throw WorkspaceError.operationFailed(L10n.string("conversion.error.package_too_large"))
            }
            let localOffset = UInt32(offset)
            var header = Data()
            header.appendLittleEndian(UInt32(0x0403_4B50))
            header.appendLittleEndian(UInt16(20))
            header.appendLittleEndian(UInt16(0x0800))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(checksum)
            header.appendLittleEndian(UInt32(size))
            header.appendLittleEndian(UInt32(size))
            header.appendLittleEndian(UInt16(path.count))
            header.appendLittleEndian(UInt16(0))
            header.append(path)
            try emit(header)
            if let file {
                let reader = try FileHandle(forReadingFrom: file)
                defer { try? reader.close() }
                var copied = 0
                while let data = try reader.read(upToCount: 256 * 1_024), !data.isEmpty {
                    try Task.checkCancellation()
                    try emit(data)
                    copied += data.count
                }
                guard copied == size else { throw WorkspaceError.cannotOpen(file) }
            } else { try emit(entry.data) }
            central.appendLittleEndian(UInt32(0x0201_4B50))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(0x0800))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(checksum)
            central.appendLittleEndian(UInt32(size))
            central.appendLittleEndian(UInt32(size))
            central.appendLittleEndian(UInt16(path.count))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(UInt32(0))
            central.appendLittleEndian(localOffset)
            central.append(path)
        }
        let centralOffset = UInt32(offset)
        try emit(central)
        var footer = Data()
        footer.appendLittleEndian(UInt32(0x0605_4B50))
        footer.appendLittleEndian(UInt16(0))
        footer.appendLittleEndian(UInt16(0))
        footer.appendLittleEndian(UInt16(entries.count))
        footer.appendLittleEndian(UInt16(entries.count))
        footer.appendLittleEndian(UInt32(central.count))
        footer.appendLittleEndian(centralOffset)
        footer.appendLittleEndian(UInt16(0))
        try emit(footer)
        try handle.synchronize()
    }

    static func archive(_ entries: [Entry]) throws -> Data {
        guard !entries.isEmpty, entries.count <= Int(UInt16.max) else {
            throw WorkspaceError.operationFailed(
                L10n.string("conversion.error.package_too_large")
            )
        }

        var output = Data()
        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)
        var seenPaths: Set<String> = []

        for entry in entries {
            guard
                !entry.path.isEmpty,
                !entry.path.hasPrefix("/"),
                !entry.path.contains(".."),
                seenPaths.insert(entry.path).inserted,
                let pathData = entry.path.data(using: .utf8),
                pathData.count <= Int(UInt16.max),
                entry.data.count <= Int(UInt32.max),
                output.count <= Int(UInt32.max)
            else {
                throw WorkspaceError.operationFailed(
                    L10n.string("conversion.error.package_invalid")
                )
            }

            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            output.appendLittleEndian(UInt32(0x0403_4B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800)) // UTF-8 filename
            output.appendLittleEndian(UInt16(0)) // stored
            output.appendLittleEndian(UInt16(0)) // deterministic time
            output.appendLittleEndian(UInt16(0)) // deterministic date
            output.appendLittleEndian(crc)
            output.appendLittleEndian(size)
            output.appendLittleEndian(size)
            output.appendLittleEndian(UInt16(pathData.count))
            output.appendLittleEndian(UInt16(0))
            output.append(pathData)
            output.append(entry.data)

            centralRecords.append(
                CentralRecord(
                    pathData: pathData,
                    crc32: crc,
                    size: size,
                    localHeaderOffset: offset
                )
            )
        }

        guard output.count <= Int(UInt32.max) else {
            throw WorkspaceError.operationFailed(
                L10n.string("conversion.error.package_too_large")
            )
        }
        let centralOffset = UInt32(output.count)

        for record in centralRecords {
            output.appendLittleEndian(UInt32(0x0201_4B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(record.crc32)
            output.appendLittleEndian(record.size)
            output.appendLittleEndian(record.size)
            output.appendLittleEndian(UInt16(record.pathData.count))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(record.localHeaderOffset)
            output.append(record.pathData)
        }

        guard output.count <= Int(UInt32.max) else {
            throw WorkspaceError.operationFailed(
                L10n.string("conversion.error.package_too_large")
            )
        }
        let centralSize = UInt32(output.count) - centralOffset
        let count = UInt16(centralRecords.count)
        output.appendLittleEndian(UInt32(0x0605_4B50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(count)
        output.appendLittleEndian(count)
        output.appendLittleEndian(centralSize)
        output.appendLittleEndian(centralOffset)
        output.appendLittleEndian(UInt16(0))
        return output
    }
}

private enum CRC32 {
    static func checksum(file: URL) throws -> UInt32 {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var value: UInt32 = 0xFFFF_FFFF
        while let data = try reader.read(upToCount: 256 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            for byte in data { value = update(value, byte) }
        }
        return value ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    private static func update(_ value: UInt32, _ byte: UInt8) -> UInt32 {
        (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)]
    }
    static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = update(value, byte)
        }
        return value ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
