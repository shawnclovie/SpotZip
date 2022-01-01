import Foundation

/// A custom handler that consumes data containing partial entry data.
/// - Parameters:
///   - data: A chunk of `Data` to consume.
public typealias ZipDataConsumer = (_ data: Data) throws -> Void

/// A custom handler that receives a position and a size that can be used to provide data from an arbitrary source.
/// - Parameters:
///   - position: The current read position.
///   - size: The size of the chunk to provide.
/// - Returns: A chunk of `Data`.
public typealias ZipDataProvider = (_ position: Int, _ size: Int) throws -> Data

/// A sequence of uncompressed or compressed ZIP entries.
///
/// You use an `Archive` to create, read or update ZIP files.
/// To read an existing ZIP file, you have to pass in an existing file `URL` and `AccessMode.read`:
///
///     let archive = try ZipArchive(url: URL(fileURLWithPath: "/path/file.zip"), for: .read)
///
/// An `Archive` is a sequence of entries. You can
/// iterate over an archive using a `for`-`in` loop to get access to individual `Entry` objects:
///
///     for entry in archive {
///         print(entry.path)
///     }
///
/// Each `Entry` in an `Archive` is represented by its `path`. You can
/// use `path` to retrieve the corresponding `Entry` from an `Archive` via subscripting:
///
///     let entry = archive['/path/file.txt']
///
/// To create a new `Archive`, pass in a non-existing file URL and `AccessMode.create`. To modify an
/// existing `Archive` use `AccessMode.update`:
///
///     let archive = try ZipArchive(url: URL(fileURLWithPath: "/path/file.zip"), for: .update)
///     try archive.addEntry("test.txt", relativeTo: baseURL, compressionMethod: .deflate)
public final class ZipArchive: Sequence {

	/// The access mode for an `Archive`.
	public enum AccessMode: UInt {
		case create, read, update
	}

	public enum Level: UInt16 {
		/// Indicates that an `Entry` has no compression applied to its contents.
		case store = 0

		/// Indicates that contents of an `Entry` have been compressed with a zlib compatible Deflate algorithm.
		case deflate = 8
	}

	struct EndOfCentralDirectoryRecord: DataSerializable {
		let endOfCentralDirectorySignature = UInt32(endOfCentralDirectoryStructSignature)
		let numberOfDisk: UInt16
		let numberOfDiskStart: UInt16
		let totalNumberOfEntriesOnDisk: UInt16
		let totalNumberOfEntriesInCentralDirectory: UInt16
		let sizeOfCentralDirectory: UInt32
		let offsetToStartOfCentralDirectory: UInt32
		let zipFileCommentLength: UInt16
		let zipFileCommentData: Data
		
		static let size = 22
	}
	
	/// URL of an Archive's backing file.
	public let path: URL
	
	/// Access mode for an archive file.
	public let accessMode: AccessMode
	var archiveFile: UnsafeMutablePointer<FILE>
	var endOfCentralDirectoryRecord: EndOfCentralDirectoryRecord
	
	/// Initializes a new ZIP `Archive` to create new archive files or to read and update existing ones.
	///
	/// - Parameters:
	///   - url: File URL to the receivers backing file.
	///     - The file URL _must_ point to an existing file for `.read` or `.update`
	///     - The file URL _must_ point to a non-existing file for `.write`
	///   - mode: Access mode.
	public init(path: URL, mode: AccessMode) throws {
		self.path = path
		accessMode = mode
		let fileManager = FileManager()
		switch mode {
		case .read:
			guard fileManager.fileExists(atPath: path.path) else {
				throw ZipError(.fileNotFound)
			}
			guard fileManager.isReadableFile(atPath: path.path) else {
				throw ZipError(.fileNotAccessable)
			}
			let fileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: path.path)
			archiveFile = fopen(fileSystemRepresentation, "rb")
			guard let record = ZipArchive.scanForEndOfCentralDirectoryRecord(in: archiveFile) else {
				throw ZipError(.invalidFormat)
			}
			endOfCentralDirectoryRecord = record
		case .create:
			guard !fileManager.fileExists(atPath: path.path) else {
				throw ZipError(.fileNotAccessable, userInfo: [NSFilePathErrorKey: path.path])
			}
			let record = EndOfCentralDirectoryRecord(
				numberOfDisk: 0, numberOfDiskStart: 0,
				totalNumberOfEntriesOnDisk: 0,
				totalNumberOfEntriesInCentralDirectory: 0,
				sizeOfCentralDirectory: 0,
				offsetToStartOfCentralDirectory: 0,
				zipFileCommentLength: 0,
				zipFileCommentData: Data())
			guard fileManager.createFile(atPath: path.path, contents: record.data, attributes: nil) else {
				throw ZipError(.fileNotAccessable, userInfo: [NSFilePathErrorKey: path.path])
			}
			fallthrough
		case .update:
			guard fileManager.isWritableFile(atPath: path.path) else {
				throw ZipError(.fileNotAccessable, userInfo: [NSFilePathErrorKey: path.path])
			}
			let representation = fileManager.fileSystemRepresentation(withPath: path.path)
			archiveFile = fopen(representation, "rb+")
			guard let record = ZipArchive.scanForEndOfCentralDirectoryRecord(in: archiveFile) else {
				throw ZipError(.invalidFormat, userInfo: [NSFilePathErrorKey: path.path])
			}
			endOfCentralDirectoryRecord = record
			fseek(archiveFile, 0, SEEK_SET)
		}
		setvbuf(archiveFile, nil, _IOFBF, Int(GZip.chunkSize))
	}
	
	deinit {
		fclose(archiveFile)
	}
	
	public func makeIterator() -> AnyIterator<ZipEntry> {
		let record = endOfCentralDirectoryRecord
		var directoryIndex = Int(record.offsetToStartOfCentralDirectory)
		var index = 0
		return AnyIterator {
			guard index < Int(record.totalNumberOfEntriesInCentralDirectory) else {return nil}
			guard let structure: ZipEntry.CentralDirectoryStructure = GZip.readStruct(from: self.archiveFile, at: directoryIndex) else {return nil}
			let offset = Int(structure.relativeOffsetOfLocalHeader)
			guard let header: ZipEntry.LocalFileHeader = GZip.readStruct(from: self.archiveFile, at: offset) else {return nil}
			var descriptor: ZipEntry.DataDescriptor? = nil
			if structure.usesDataDescriptor {
				let dataSize = structure.compressionMethod != Level.store.rawValue ? structure.compressedSize : structure.uncompressedSize
				let position = offset
					+ ZipEntry.LocalFileHeader.size
					+ Int(header.fileNameLength + header.extraFieldLength)
					+ Int(dataSize)
				descriptor = GZip.readStruct(from: self.archiveFile, at: position)
			}
			defer {
				directoryIndex += ZipEntry.CentralDirectoryStructure.size + Int(structure.fileNameLength + structure.extraFieldLength + structure.fileCommentLength)
				index += 1
			}
			return ZipEntry(structure, header, descriptor)
		}
	}
	
	/// Retrieve the ZIP `Entry` with the given `path` from the receiver.
	///
	/// - Note: The ZIP file format specification does not enforce unique paths for entries.
	///   Therefore an archive can contain multiple entries with the same path. This method always returns the first `Entry` with the given `path`.
	///
	/// - Parameter path: A relative file path identifiying the corresponding `Entry`.
	/// - Returns: An `Entry` with the given `path`. Otherwise, `nil`.
	public subscript(path: String) -> ZipEntry? {
		for it in self where it.path == path {
			return it
		}
		return nil
	}
	
	// MARK: - Helpers
	
	private static func scanForEndOfCentralDirectoryRecord(in file: UnsafeMutablePointer<FILE>) -> EndOfCentralDirectoryRecord? {
		var directoryEnd = 0
		var index = Self.minDirectoryEndOffset
		var fileStat = stat()
		fstat(fileno(file), &fileStat)
		let archiveLength = Int(fileStat.st_size)
		while directoryEnd == 0 && index < Self.maxDirectoryEndOffset && index <= archiveLength {
			fseek(file, archiveLength - index, SEEK_SET)
			var potentialDirectoryEndTag: UInt32 = UInt32()
			fread(&potentialDirectoryEndTag, 1, MemoryLayout<UInt32>.size, file)
			if potentialDirectoryEndTag == UInt32(Self.endOfCentralDirectoryStructSignature) {
				directoryEnd = archiveLength - index
				return GZip.readStruct(from: file, at: directoryEnd)
			}
			index += 1
		}
		return nil
	}

	static let directoryUnitCount = Int64(1)
	static let minDirectoryEndOffset = 22
	static let maxDirectoryEndOffset = 66000
	static let endOfCentralDirectoryStructSignature = 0x06054b50
	static let localFileHeaderStructSignature = 0x04034b50
	static let dataDescriptorStructSignature = 0x08074b50
	static let centralDirectoryStructSignature = 0x02014b50
}

extension ZipArchive {
	/// The number of the work units that have to be performed when removing `entry` from the receiver.
	///
	/// - Parameter entry: The entry that will be removed.
	/// - Returns: The number of the work units.
	public func totalUnitCount(removing entry: ZipEntry) -> Int64 {
		Int64(endOfCentralDirectoryRecord.offsetToStartOfCentralDirectory - UInt32(entry.localSize))
	}
	
	func makeProgress(removing entry: ZipEntry) -> Progress {
		Progress(totalUnitCount: totalUnitCount(removing: entry))
	}
	
	/// The number of the work units that have to be performed when reading `entry` from the receiver.
	///
	/// - Parameter entry: The entry that will be read.
	/// - Returns: The number of the work units.
	public func totalUnitCount(reading entry: ZipEntry) -> Int64 {
		switch entry.type {
		case .file, .symlink:
			return Int64(entry.uncompressedSize)
		case .directory:
			return Self.directoryUnitCount
		}
	}
	
	func makeProgress(reading entry: ZipEntry) -> Progress {
		Progress(totalUnitCount: totalUnitCount(reading: entry))
	}
	
	/// The number of the work units that have to be performed when adding the file at `url` to the receiver.
	/// - Parameter entry: The entry that will be removed.
	/// - Returns: The number of the work units.
	public func totalUnitCount(addingItem url: URL) -> Int64 {
		let fileManager = FileManager()
		do {
			let type = try ZipArchive.typeForItem(path: url, with: fileManager)
			switch type {
			case .file, .symlink:
				return Int64(try fileManager.fileSizeForItem(at: url))
			case .directory:
				return Self.directoryUnitCount
			}
		} catch {
			return -1
		}
	}
}

extension ZipArchive.EndOfCentralDirectoryRecord {
	var data: Data {
		var endOfCentralDirectorySignature = self.endOfCentralDirectorySignature
		var numberOfDisk = self.numberOfDisk
		var numberOfDiskStart = self.numberOfDiskStart
		var totalNumberOfEntriesOnDisk = self.totalNumberOfEntriesOnDisk
		var totalNumberOfEntriesInCentralDirectory = self.totalNumberOfEntriesInCentralDirectory
		var sizeOfCentralDirectory = self.sizeOfCentralDirectory
		var offsetToStartOfCentralDirectory = self.offsetToStartOfCentralDirectory
		var zipFileCommentLength = self.zipFileCommentLength
		var data = Data(buffer: UnsafeBufferPointer(start: &endOfCentralDirectorySignature, count: 1))
		data.append(UnsafeBufferPointer(start: &numberOfDisk, count: 1))
		data.append(UnsafeBufferPointer(start: &numberOfDiskStart, count: 1))
		data.append(UnsafeBufferPointer(start: &totalNumberOfEntriesOnDisk, count: 1))
		data.append(UnsafeBufferPointer(start: &totalNumberOfEntriesInCentralDirectory, count: 1))
		data.append(UnsafeBufferPointer(start: &sizeOfCentralDirectory, count: 1))
		data.append(UnsafeBufferPointer(start: &offsetToStartOfCentralDirectory, count: 1))
		data.append(UnsafeBufferPointer(start: &zipFileCommentLength, count: 1))
		data.append(zipFileCommentData)
		return data
	}
	
	init?(data: Data, additionalDataProvider provider: (Int) throws -> Data) {
		guard data.count == ZipArchive.EndOfCentralDirectoryRecord.size else {return nil}
		guard GZip.scanValue(data, start: 0) == endOfCentralDirectorySignature else {return nil}
		numberOfDisk = GZip.scanValue(data, start: 4)
		numberOfDiskStart = GZip.scanValue(data, start: 6)
		totalNumberOfEntriesOnDisk = GZip.scanValue(data, start: 8)
		totalNumberOfEntriesInCentralDirectory = GZip.scanValue(data, start: 10)
		sizeOfCentralDirectory = GZip.scanValue(data, start: 12)
		offsetToStartOfCentralDirectory = GZip.scanValue(data, start: 16)
		zipFileCommentLength = GZip.scanValue(data, start: 20)
		guard let commentData = try? provider(Int(zipFileCommentLength)) else {return nil}
		guard commentData.count == Int(zipFileCommentLength) else {return nil}
		zipFileCommentData = commentData
	}
	
	init(record: ZipArchive.EndOfCentralDirectoryRecord,
		 numberOfEntriesOnDisk: UInt16,
		 numberOfEntriesInCentralDirectory: UInt16,
		 updatedSizeOfCentralDirectory: UInt32,
		 startOfCentralDirectory: UInt32) {
		numberOfDisk = record.numberOfDisk
		numberOfDiskStart = record.numberOfDiskStart
		totalNumberOfEntriesOnDisk = numberOfEntriesOnDisk
		totalNumberOfEntriesInCentralDirectory = numberOfEntriesInCentralDirectory
		sizeOfCentralDirectory = updatedSizeOfCentralDirectory
		offsetToStartOfCentralDirectory = startOfCentralDirectory
		zipFileCommentLength = record.zipFileCommentLength
		zipFileCommentData = record.zipFileCommentData
	}
}
