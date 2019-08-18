//
//  ZipEntry.swift
//  Spot
//
//  Created by Shawn Clovie on 7/16/2018.
//  Copyright © 2018 Shawn Clovie. All rights reserved.
//

import Foundation
import CoreFoundation

/// A value that represents a file, a direcotry or a symbolic link within a ZIP `Archive`.
///
/// You can retrieve instances of `Entry` from an `Archive` via subscripting with their path or iteration.
public struct ZipEntry: Equatable {
	
	public enum EntryType: Int {
		case file, directory, symlink
		
		init(mode: mode_t) {
			switch mode & S_IFMT {
			case S_IFDIR:	self = .directory
			case S_IFLNK:	self = .symlink
			default:		self = .file
			}
		}
		
		func entryExternalFileAttributes(permissions: UInt16) -> UInt32 {
			let typeInt: UInt16
			switch self {
			case .file:		typeInt = UInt16(S_IFREG)
			case .directory:typeInt = UInt16(S_IFDIR)
			case .symlink:	typeInt = UInt16(S_IFLNK)
			}
			let attributes = UInt32(typeInt | UInt16(permissions))
			return attributes << 16
		}
	}
	
	enum OSType: UInt {
		case msdos = 0
		case unix = 3
		case osx = 19
		case unused = 20
	}
	
	struct LocalFileHeader: DataSerializable {
		static let size = 30
		
		let localFileHeaderSignature = UInt32(ZipLocalFileHeaderStructSignature)
		let versionNeededToExtract: UInt16
		let generalPurposeBitFlag: UInt16
		let compressionMethod: UInt16
		let lastModFileTime: UInt16
		let lastModFileDate: UInt16
		let crc32: UInt32
		let compressedSize: UInt32
		let uncompressedSize: UInt32
		let fileNameLength: UInt16
		let extraFieldLength: UInt16
		let fileNameData: Data
		let extraFieldData: Data
	}
	
	struct DataDescriptor: DataSerializable {
		static let size = 16
		
		let data: Data
		let dataDescriptorSignature = UInt32(ZipDataDescriptorStructSignature)
		let crc32: UInt32
		let compressedSize: UInt32
		let uncompressedSize: UInt32
	}
	
	struct CentralDirectoryStructure: DataSerializable {
		static let size = 46
		
		let centralDirectorySignature = UInt32(ZipCentralDirectoryStructSignature)
		let versionMadeBy: UInt16
		let versionNeededToExtract: UInt16
		let generalPurposeBitFlag: UInt16
		let compressionMethod: UInt16
		let lastModFileTime: UInt16
		let lastModFileDate: UInt16
		let crc32: UInt32
		let compressedSize: UInt32
		let uncompressedSize: UInt32
		let fileNameLength: UInt16
		let extraFieldLength: UInt16
		let fileCommentLength: UInt16
		let diskNumberStart: UInt16
		let internalFileAttributes: UInt16
		let externalFileAttributes: UInt32
		let relativeOffsetOfLocalHeader: UInt32
		let fileNameData: Data
		let extraFieldData: Data
		let fileCommentData: Data
		
		var usesDataDescriptor: Bool {
			(generalPurposeBitFlag & (1 << 3 )) != 0
		}
		var isZIP64: Bool {
			versionNeededToExtract >= 45
		}
		var isEncrypted: Bool {
			(generalPurposeBitFlag & (1 << 0)) != 0
		}
		
		var lastModifyDate: Date {
			var dosTime = Int(lastModFileDate)
			dosTime <<= 16
			dosTime |= Int(lastModFileTime)
			var unixTime = tm()
			unixTime.tm_sec = Int32((dosTime & 31) * 2)
			unixTime.tm_min = Int32((dosTime >> 5) & 63)
			unixTime.tm_hour = Int32((Int(lastModFileTime) >> 11) & 31)
			unixTime.tm_mday = Int32((dosTime >> 16) & 31)
			unixTime.tm_mon = Int32((dosTime >> 21) & 15)
			unixTime.tm_mon -= 1 // UNIX time struct month entries are zero based.
			unixTime.tm_year = Int32(1980 + (dosTime >> 25))
			unixTime.tm_year -= 1900 // UNIX time structs count in "years since 1900".
			return Date(timeIntervalSince1970: TimeInterval(timegm(&unixTime)))
		}
	}
	
	public static func == (lhs: ZipEntry, rhs: ZipEntry) -> Bool {
		lhs.path == rhs.path
			&& lhs.localFileHeader.crc32
			== rhs.localFileHeader.crc32
			&& lhs.centralDirectoryStructure.relativeOffsetOfLocalHeader
			== rhs.centralDirectoryStructure.relativeOffsetOfLocalHeader
	}
	
	let centralDirectoryStructure: CentralDirectoryStructure
	let localFileHeader: LocalFileHeader
	let dataDescriptor: DataDescriptor?
	
	init?(_ structure: CentralDirectoryStructure, _ header: LocalFileHeader, _ descriptor: DataDescriptor?) {
		// We currently don't support ZIP64 or encrypted archives
		guard !structure.isZIP64 else {return nil}
		guard !structure.isEncrypted else {return nil}
		centralDirectoryStructure = structure
		localFileHeader = header
		dataDescriptor = descriptor
	}
	
	/// The `path` of the receiver within a ZIP `Archive`.
	public var path: String {
		let dosLatinUS = 0x400
		let isUTF8 = ((centralDirectoryStructure.generalPurposeBitFlag >> 11) & 1) != 0
		let encoding = isUTF8 ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(dosLatinUS)))
		return String(data: centralDirectoryStructure.fileNameData, encoding: encoding) ?? ""
	}
	
	/// The file attributes of the receiver as key/value pairs.
	///
	/// Contains the modification date and file permissions.
	public var fileAttributes: [FileAttributeKey: Any] {
		let structure = centralDirectoryStructure
		var attributes: [FileAttributeKey: Any] = [
			.posixPermissions: type == .directory ? ZipEntryDefaultDirectoryPermissions : ZipEntryDefaultFilePermissions,
			.modificationDate: Date()]
		let versionMadeBy = structure.versionMadeBy
		guard let os = ZipEntry.OSType(rawValue: UInt(versionMadeBy >> 8)) else {
			return attributes
		}
		let permissions = ZipEntry.permissions(for: structure.externalFileAttributes, on: os, of: type)
		attributes[.posixPermissions] = NSNumber(value: permissions)
		attributes[.modificationDate] = structure.lastModifyDate
		return attributes
	}
	
	private static func permissions(for externalFileAttrs: UInt32, on os: ZipEntry.OSType, of type: ZipEntry.EntryType) -> UInt16 {
		switch os {
		case .unix, .osx:
			let permissions = mode_t(externalFileAttrs >> 16) & (~S_IFMT)
			if permissions == 0 {
				return type == .directory ? ZipEntryDefaultDirectoryPermissions : ZipEntryDefaultFilePermissions
			}
			return permissions
		default:
			return type == .directory ? ZipEntryDefaultDirectoryPermissions : ZipEntryDefaultFilePermissions
		}
	}

	/// The `CRC32` checksum of the receiver.
	///
	/// - Note: Always returns `0` for entries of type `EntryType.directory`.
	public var checksum: CRC32 {
		var checksum = centralDirectoryStructure.crc32
		if centralDirectoryStructure.usesDataDescriptor {
			guard let dataDescriptor = dataDescriptor else {
				return 0
			}
			checksum = dataDescriptor.crc32
		}
		return checksum
	}
	
	/// The `EntryType` of the receiver.
	public var type: EntryType {
		// OS Type is stored in the upper byte of versionMadeBy
		let os = OSType(rawValue: UInt(centralDirectoryStructure.versionMadeBy >> 8)) ?? .unused
		var isDirectory = path.hasSuffix("/")
		switch os {
		case .unix, .osx:
			let mode = mode_t(centralDirectoryStructure.externalFileAttributes >> 16) & S_IFMT
			switch mode {
			case S_IFREG:	return .file
			case S_IFDIR:	return .directory
			case S_IFLNK:	return .symlink
			default:		return .file
			}
		case .msdos:
			isDirectory = isDirectory || ((centralDirectoryStructure.externalFileAttributes >> 4) == 0x01)
			fallthrough
		default:
			// for all other OSes we can only guess based on the directory suffix char
			return isDirectory ? .directory : .file
		}
	}
	
	/// The size of the receiver's compressed data.
	public var compressedSize: UInt32 {
		dataDescriptor?.compressedSize ?? localFileHeader.compressedSize
	}
	
	/// The size of the receiver's uncompressed data.
	public var uncompressedSize: UInt32 {
		dataDescriptor?.uncompressedSize ?? localFileHeader.uncompressedSize
	}
	
	/// The combined size of the local header, the data and the optional data descriptor.
	var localSize: Int {
		let isCompressed = localFileHeader.compressionMethod != ZipArchiveLevel.store.rawValue
		return LocalFileHeader.size
			+ Int(localFileHeader.fileNameLength)
			+ Int(localFileHeader.extraFieldLength)
			+ Int(isCompressed ? compressedSize : uncompressedSize)
			+ (dataDescriptor != nil ? DataDescriptor.size : 0)
	}
	
	var dataOffset: Int {
		Int(centralDirectoryStructure.relativeOffsetOfLocalHeader)
			+ LocalFileHeader.size
			+ Int(localFileHeader.fileNameLength)
			+ Int(localFileHeader.extraFieldLength)
	}
}

extension ZipEntry.LocalFileHeader {
	
	var data: Data {
		var localFileHeaderSignature = self.localFileHeaderSignature
		var versionNeededToExtract = self.versionNeededToExtract
		var generalPurposeBitFlag = self.generalPurposeBitFlag
		var compressionMethod = self.compressionMethod
		var lastModFileTime = self.lastModFileTime
		var lastModFileDate = self.lastModFileDate
		var crc32 = self.crc32
		var compressedSize = self.compressedSize
		var uncompressedSize = self.uncompressedSize
		var fileNameLength = self.fileNameLength
		var extraFieldLength = self.extraFieldLength
		var data = Data(buffer: UnsafeBufferPointer(start: &localFileHeaderSignature, count: 1))
		data.append(UnsafeBufferPointer(start: &versionNeededToExtract, count: 1))
		data.append(UnsafeBufferPointer(start: &generalPurposeBitFlag, count: 1))
		data.append(UnsafeBufferPointer(start: &compressionMethod, count: 1))
		data.append(UnsafeBufferPointer(start: &lastModFileTime, count: 1))
		data.append(UnsafeBufferPointer(start: &lastModFileDate, count: 1))
		data.append(UnsafeBufferPointer(start: &crc32, count: 1))
		data.append(UnsafeBufferPointer(start: &compressedSize, count: 1))
		data.append(UnsafeBufferPointer(start: &uncompressedSize, count: 1))
		data.append(UnsafeBufferPointer(start: &fileNameLength, count: 1))
		data.append(UnsafeBufferPointer(start: &extraFieldLength, count: 1))
		data.append(self.fileNameData)
		data.append(self.extraFieldData)
		return data
	}
	
	init?(data: Data, additionalDataProvider provider: (Int) throws -> Data) {
		guard data.count == ZipEntry.LocalFileHeader.size else {return nil}
		guard data.scanValue(start: 0) == localFileHeaderSignature else {return nil}
		versionNeededToExtract = data.scanValue(start: 4)
		generalPurposeBitFlag = data.scanValue(start: 6)
		compressionMethod = data.scanValue(start: 8)
		lastModFileTime = data.scanValue(start: 10)
		lastModFileDate = data.scanValue(start: 12)
		crc32 = data.scanValue(start: 14)
		compressedSize = data.scanValue(start: 18)
		uncompressedSize = data.scanValue(start: 22)
		fileNameLength = data.scanValue(start: 26)
		extraFieldLength = data.scanValue(start: 28)
		let additionalDataLength = Int(fileNameLength + extraFieldLength)
		guard let additionalData = try? provider(additionalDataLength) else {return nil}
		guard additionalData.count == additionalDataLength else {return nil}
		let nameLen = Int(fileNameLength)
		fileNameData = additionalData.subdata(in: 0..<nameLen)
		let subRangeEnd = nameLen + Int(extraFieldLength)
		extraFieldData = additionalData.subdata(in: nameLen..<subRangeEnd)
	}
}

extension ZipEntry.CentralDirectoryStructure {
	var data: Data {
		var centralDirectorySignature = self.centralDirectorySignature
		var versionMadeBy = self.versionMadeBy
		var versionNeededToExtract = self.versionNeededToExtract
		var generalPurposeBitFlag = self.generalPurposeBitFlag
		var compressionMethod = self.compressionMethod
		var lastModFileTime = self.lastModFileTime
		var lastModFileDate = self.lastModFileDate
		var crc32 = self.crc32
		var compressedSize = self.compressedSize
		var uncompressedSize = self.uncompressedSize
		var fileNameLength = self.fileNameLength
		var extraFieldLength = self.extraFieldLength
		var fileCommentLength = self.fileCommentLength
		var diskNumberStart = self.diskNumberStart
		var internalFileAttributes = self.internalFileAttributes
		var externalFileAttributes = self.externalFileAttributes
		var relativeOffsetOfLocalHeader = self.relativeOffsetOfLocalHeader
		var data = Data(buffer: UnsafeBufferPointer(start: &centralDirectorySignature, count: 1))
		data.append(UnsafeBufferPointer(start: &versionMadeBy, count: 1))
		data.append(UnsafeBufferPointer(start: &versionNeededToExtract, count: 1))
		data.append(UnsafeBufferPointer(start: &generalPurposeBitFlag, count: 1))
		data.append(UnsafeBufferPointer(start: &compressionMethod, count: 1))
		data.append(UnsafeBufferPointer(start: &lastModFileTime, count: 1))
		data.append(UnsafeBufferPointer(start: &lastModFileDate, count: 1))
		data.append(UnsafeBufferPointer(start: &crc32, count: 1))
		data.append(UnsafeBufferPointer(start: &compressedSize, count: 1))
		data.append(UnsafeBufferPointer(start: &uncompressedSize, count: 1))
		data.append(UnsafeBufferPointer(start: &fileNameLength, count: 1))
		data.append(UnsafeBufferPointer(start: &extraFieldLength, count: 1))
		data.append(UnsafeBufferPointer(start: &fileCommentLength, count: 1))
		data.append(UnsafeBufferPointer(start: &diskNumberStart, count: 1))
		data.append(UnsafeBufferPointer(start: &internalFileAttributes, count: 1))
		data.append(UnsafeBufferPointer(start: &externalFileAttributes, count: 1))
		data.append(UnsafeBufferPointer(start: &relativeOffsetOfLocalHeader, count: 1))
		data.append(fileNameData)
		data.append(extraFieldData)
		data.append(fileCommentData)
		return data
	}
	
	init?(data: Data, additionalDataProvider provider: (Int) throws -> Data) {
		guard data.count == ZipEntry.CentralDirectoryStructure.size else {return nil}
		guard data.scanValue(start: 0) == centralDirectorySignature else {return nil}
		versionMadeBy = data.scanValue(start: 4)
		versionNeededToExtract = data.scanValue(start: 6)
		generalPurposeBitFlag = data.scanValue(start: 8)
		compressionMethod = data.scanValue(start: 10)
		lastModFileTime = data.scanValue(start: 12)
		lastModFileDate = data.scanValue(start: 14)
		crc32 = data.scanValue(start: 16)
		compressedSize = data.scanValue(start: 20)
		uncompressedSize = data.scanValue(start: 24)
		fileNameLength = data.scanValue(start: 28)
		extraFieldLength = data.scanValue(start: 30)
		fileCommentLength = data.scanValue(start: 32)
		diskNumberStart = data.scanValue(start: 34)
		internalFileAttributes = data.scanValue(start: 36)
		externalFileAttributes = data.scanValue(start: 38)
		relativeOffsetOfLocalHeader = data.scanValue(start: 42)
		let additionalDataLength = Int(fileNameLength + extraFieldLength + fileCommentLength)
		guard let additionalData = try? provider(additionalDataLength) else {return nil}
		guard additionalData.count == additionalDataLength else {return nil}
		let nameLen = Int(fileNameLength)
		fileNameData = additionalData.subdata(in: 0..<nameLen)
		extraFieldData = additionalData.subdata(in: nameLen..<(nameLen + Int(extraFieldLength)))
		let subRangeStart = nameLen + Int(extraFieldLength)
		fileCommentData = additionalData.subdata(in: subRangeStart..<(subRangeStart + Int(fileCommentLength)))
	}
	
	init(from header: ZipEntry.LocalFileHeader, fileAttributes: UInt32, relativeOffset: UInt32) {
		versionMadeBy = 789
		versionNeededToExtract = header.versionNeededToExtract
		generalPurposeBitFlag = header.generalPurposeBitFlag
		compressionMethod = header.compressionMethod
		lastModFileTime = header.lastModFileTime
		lastModFileDate = header.lastModFileDate
		crc32 = header.crc32
		compressedSize = header.compressedSize
		uncompressedSize = header.uncompressedSize
		fileNameLength = header.fileNameLength
		extraFieldLength = 0
		fileCommentLength = 0
		diskNumberStart = 0
		internalFileAttributes = 0
		externalFileAttributes = fileAttributes
		relativeOffsetOfLocalHeader = relativeOffset
		fileNameData = header.fileNameData
		extraFieldData = Data()
		fileCommentData = Data()
	}
	
	init(from structure: ZipEntry.CentralDirectoryStructure, offset: UInt32) {
		let relativeOffset = structure.relativeOffsetOfLocalHeader - offset
		relativeOffsetOfLocalHeader = relativeOffset
		versionMadeBy = structure.versionMadeBy
		versionNeededToExtract = structure.versionNeededToExtract
		generalPurposeBitFlag = structure.generalPurposeBitFlag
		compressionMethod = structure.compressionMethod
		lastModFileTime = structure.lastModFileTime
		lastModFileDate = structure.lastModFileDate
		crc32 = structure.crc32
		compressedSize = structure.compressedSize
		uncompressedSize = structure.uncompressedSize
		fileNameLength = structure.fileNameLength
		extraFieldLength = structure.extraFieldLength
		fileCommentLength = structure.fileCommentLength
		diskNumberStart = structure.diskNumberStart
		internalFileAttributes = structure.internalFileAttributes
		externalFileAttributes = structure.externalFileAttributes
		fileNameData = structure.fileNameData
		extraFieldData = structure.extraFieldData
		fileCommentData = structure.fileCommentData
	}
}

extension ZipEntry.DataDescriptor {
	init?(data: Data, additionalDataProvider provider: (Int) throws -> Data) {
		guard data.count == ZipEntry.DataDescriptor.size else {return nil}
		let signature: UInt32 = data.scanValue(start: 0)
		// The DataDescriptor signature is not mandatory so we have to re-arrange the input data if it is missing
		let offset = signature == dataDescriptorSignature ? 4 : 0
		crc32 = data.scanValue(start: offset + 0)
		compressedSize = data.scanValue(start: offset + 4)
		uncompressedSize = data.scanValue(start: offset + 8)
		// Our add(_ entry:) methods always maintain compressed & uncompressed sizes and so we don't need a data descriptor for newly added entries.
		// Data descriptors of already existing entries are manually preserved when copying those entries to the tempArchive during remove(_ entry:).
		self.data = Data()
	}
}
