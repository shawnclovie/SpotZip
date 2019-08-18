//
//  ZipArchive+Reading.swift
//  Spot
//
//  Created by Shawn Clovie on 7/16/2018.
//  Copyright © 2018 Shawn Clovie. All rights reserved.
//

import Foundation
import Spot

extension ZipArchive {
    /// Read a ZIP `Entry` from the receiver and write it to `url`.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - url: The destination file URL.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    /// - Returns: The checksum of the processed content.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
	@discardableResult
    public func extract(_ entry: ZipEntry, to url: URL,
						bufferSize: UInt32 = ZipReadChunkSize,
                        progress: Progress? = nil) throws -> CRC32 {
        let fileManager = FileManager()
		let checksum: CRC32
        switch entry.type {
        case .file:
            guard !fileManager.fileExists(atPath: url.path) else {
                throw AttributedError(.fileDidExists, userInfo: [NSFilePathErrorKey: url.path])
            }
			try fileManager.createDirectoryIfNotExists(for: url.deletingLastPathComponent())
            let representation = fileManager.fileSystemRepresentation(withPath: url.path)
            let destFile: UnsafeMutablePointer<FILE> = fopen(representation, "wb+")
            defer {
				fclose(destFile)
			}
			checksum = try extract(entry, bufferSize: bufferSize, progress: progress) {
				_ = try $0.write(to: destFile)
			}
        case .directory:
			checksum = try extract(entry, bufferSize: bufferSize, progress: progress) { (_: Data) in
				try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
			}
        case .symlink:
            guard !fileManager.fileExists(atPath: url.path) else {
                throw AttributedError(.fileDidExists, userInfo: [NSFilePathErrorKey: url.path])
            }
			checksum = try extract(entry, bufferSize: bufferSize, progress: progress) { (data) in
				try fileManager.createDirectoryIfNotExists(for: url.deletingLastPathComponent())
				let linkPath = String(decoding: data, as: UTF8.self)
				try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: linkPath)
			}
        }
        try fileManager.setAttributes(entry.fileAttributes, ofItemAtPath: url.path)
        return checksum
    }

    /// Read a ZIP `Entry` from the receiver and forward its contents to a `Consumer` closure.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    ///   - consumer: A closure that consumes contents of `Entry` as `Data` chunks.
    /// - Returns: The checksum of the processed content.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    public func extract(_ entry: ZipEntry,
						bufferSize: UInt32 = ZipReadChunkSize,
                        progress: Progress? = nil,
						consumer: ZipDataConsumer) throws -> CRC32 {
		let checksum: CRC32
        fseek(archiveFile, entry.dataOffset, SEEK_SET)
		progress?.totalUnitCount = totalUnitCount(reading: entry)
        switch entry.type {
        case .file:
            guard let method = ZipArchiveLevel(rawValue: entry.localFileHeader.compressionMethod) else {
                throw AttributedError(ZipErrorSource.invalidArchiveLevel)
            }
            switch method {
            case .store:
				checksum = try readUncompressed(entry: entry, bufferSize: bufferSize, progress: progress, with: consumer)
            case .deflate:
				checksum = try readCompressed(entry: entry, bufferSize: bufferSize, progress: progress, with: consumer)
            }
        case .directory:
            try consumer(Data())
			checksum = 0
            progress?.completedUnitCount = totalUnitCount(reading: entry)
        case .symlink:
            let size = Int(entry.localFileHeader.compressedSize)
            let data = try Data.readChunk(of: size, from: archiveFile)
            checksum = data.crc32(checksum: 0)
            try consumer(data)
            progress?.completedUnitCount = totalUnitCount(reading: entry)
        }
        return checksum
    }

    // MARK: - Helpers

    private func readUncompressed(entry: ZipEntry, bufferSize: UInt32,
                                  progress: Progress? = nil,
								  with consumer: ZipDataConsumer) throws -> CRC32 {
        let size = Int(entry.centralDirectoryStructure.uncompressedSize)
        return try Data.consumePart(of: size, chunkSize: Int(bufferSize), provider: { (_, chunkSize) in
            if progress?.isCancelled == true {
				throw AttributedError(.cancelled)
			}
            return try Data.readChunk(of: Int(chunkSize), from: self.archiveFile)
        }, consumer: { (data) in
            try consumer(data)
            progress?.completedUnitCount += Int64(data.count)
        })
    }

    private func readCompressed(entry: ZipEntry, bufferSize: UInt32,
                                progress: Progress? = nil,
								with consumer: ZipDataConsumer) throws -> CRC32 {
        let size = Int(entry.centralDirectoryStructure.compressedSize)
		if progress?.isCancelled == true {
			throw AttributedError(.cancelled)
		}
		let result = try Data.readChunk(of: Int(size), from: archiveFile)
			.spot.inflated()
		try consumer(result)
		progress?.completedUnitCount += Int64(result.count)
		return result.crc32(checksum: 0)
    }
}
