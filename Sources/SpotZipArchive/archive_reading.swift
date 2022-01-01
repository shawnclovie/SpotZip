import Foundation

extension ZipArchive {
    /// Read a ZIP `Entry` from the receiver and write it to `url`.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - targetPath: The destination file URL.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - progress: A progress object that can be used to track or cancel the extract operation.
    /// - Returns: The checksum of the processed content.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
	@discardableResult
    public func extract(_ entry: ZipEntry,
						targetPath: URL,
						bufferSize: UInt32 = GZip.chunkSize,
						progress: Progress? = nil) throws -> GZip.CRC32 {
        let fileManager = FileManager()
		let checksum: GZip.CRC32
        switch entry.type {
        case .file:
            guard !fileManager.fileExists(atPath: targetPath.path) else {
                throw ZipError(.fileNotAccessable, "file_did_exists", userInfo: [NSFilePathErrorKey: targetPath.path])
            }
			if !fileManager.fileExists(atPath: targetPath.path) {
				try fileManager.createDirectory(at: targetPath.deletingLastPathComponent(), withIntermediateDirectories: true)
			}
            let representation = fileManager.fileSystemRepresentation(withPath: targetPath.path)
            let destFile: UnsafeMutablePointer<FILE> = fopen(representation, "wb+")
            defer {
				fclose(destFile)
			}
			checksum = try extract(entry, bufferSize: bufferSize, progress: progress) {
				_ = try GZip.write($0, to: destFile)
			}
        case .directory:
			checksum = try extract(entry, bufferSize: bufferSize, progress: progress) { (_: Data) in
				try fileManager.createDirectory(at: targetPath, withIntermediateDirectories: true, attributes: nil)
			}
        case .symlink:
            guard !fileManager.fileExists(atPath: targetPath.path) else {
                throw ZipError(.fileNotAccessable, "file_did_exists", userInfo: [NSFilePathErrorKey: targetPath.path])
            }
			checksum = try extract(entry, bufferSize: bufferSize, progress: progress) { (data) in
				if !fileManager.fileExists(atPath: targetPath.path) {
					try fileManager.createDirectory(at: targetPath.deletingLastPathComponent(), withIntermediateDirectories: true)
				}
				let linkPath = String(decoding: data, as: UTF8.self)
				try fileManager.createSymbolicLink(atPath: targetPath.path, withDestinationPath: linkPath)
			}
        }
        try fileManager.setAttributes(entry.fileAttributes, ofItemAtPath: targetPath.path)
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
						bufferSize: UInt32 = GZip.chunkSize,
                        progress: Progress? = nil,
						consumer: ZipDataConsumer) throws -> GZip.CRC32 {
		let checksum: GZip.CRC32
        fseek(archiveFile, entry.dataOffset, SEEK_SET)
		progress?.totalUnitCount = totalUnitCount(reading: entry)
        switch entry.type {
        case .file:
            guard let method = Level(rawValue: entry.localFileHeader.compressionMethod) else {
				throw ZipError(.invalidArchiveLevel, userInfo: ["compression_method": entry.localFileHeader.compressionMethod])
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
			let data = try GZip.readChunk(of: size, from: archiveFile)
			checksum = GZip.crc32(data, checksum: 0)
            try consumer(data)
            progress?.completedUnitCount = totalUnitCount(reading: entry)
        }
        return checksum
    }

    // MARK: - Helpers

    private func readUncompressed(entry: ZipEntry,
								  bufferSize: UInt32,
                                  progress: Progress? = nil,
								  with consumer: ZipDataConsumer) throws -> GZip.CRC32 {
        let size = Int(entry.centralDirectoryStructure.uncompressedSize)
		return try GZip.consumePart(of: size, chunkSize: Int(bufferSize), provider: { (_, chunkSize) in
            if progress?.isCancelled == true {
				throw ZipError(.cancelled)
			}
			return try GZip.readChunk(of: Int(chunkSize), from: self.archiveFile)
        }, consumer: { (data) in
            try consumer(data)
            progress?.completedUnitCount += Int64(data.count)
        })
    }

    private func readCompressed(entry: ZipEntry, bufferSize: UInt32,
                                progress: Progress? = nil,
								with consumer: ZipDataConsumer) throws -> GZip.CRC32 {
        let size = Int(entry.centralDirectoryStructure.compressedSize)
		if progress?.isCancelled == true {
			throw ZipError(.cancelled)
		}
		let rawData = try GZip.readChunk(of: Int(size), from: archiveFile)
		let result = try GZip.inflated(rawData)
		try consumer(result)
		progress?.completedUnitCount += Int64(result.count)
		return GZip.crc32(result, checksum: 0)
    }
}
