//
//  ZipArchive+convenience.swift
//  Spot
//
//  Created by Shawn Clovie on 7/16/2018.
//  Copyright © 2018 Shawn Clovie. All rights reserved.
//

import Foundation
import Spot

extension ZipArchive {
	/// Zips the file or direcory contents at the specified source URL to the destination URL.
	///
	/// If the item at the source URL is a directory, the directory itself will be represented within the ZIP `Archive`. Calling this method with a directory URL `file:///path/directory/` will create an archive with a `directory/` entry at the root level.
	///
	/// - Parameters:
	///   - source: The file URL pointing to an existing file or directory.
	///   - destination: The file URL that identifies the destination of the zip operation.
	///   - keepParent: Indicates that the directory name of a source item should be used as root element within the archive. Default is `false`.
	///   - level: Indicates the `ZipArchiveLevel` that should be applied. Default is .deflate.
	///   - progress: A progress object that can be used to track or cancel the zip operation.
	/// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
	@available(iOS 9.0, *)
	public static func zipItem(at source: URL, to destination: URL,
							 keepParent: Bool = false,
							 by level: ZipArchiveLevel = .deflate,
							 progress: Progress? = nil) throws {
		let fileManager = FileManager()
		let isDirectory = try typeForItem(at: source, with: fileManager) == .directory
		let archive = try ZipArchive(url: destination, for: .create)
		if isDirectory {
			let subPaths = try fileManager.subpathsOfDirectory(atPath: source.path)
			var totalUnitCount = Int64(0)
			if let progress = progress {
				totalUnitCount = subPaths.reduce(Int64(0), {
					let itemURL = source.appendingPathComponent($1)
					let itemSize = archive.totalUnitCount(addingItem: itemURL)
					return $0 + itemSize
				})
				progress.totalUnitCount = totalUnitCount
			}
			let subdir = source.lastPathComponent
			for entryPath in subPaths {
				let entryURL = source.appendingPathComponent(entryPath)
				let finalEntryPath = keepParent ? subdir + "/" + entryPath : entryPath
				if let progress = progress {
					let itemURL = source.appendingPathComponent(entryPath)
					let entryProgress = Progress(totalUnitCount: archive.totalUnitCount(addingItem: itemURL))
					progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
					try archive.addEntry(at: entryURL, entryPath: finalEntryPath, by: level, progress: entryProgress)
				} else {
					try archive.addEntry(at: entryURL, entryPath: finalEntryPath, by: level)
				}
			}
		} else {
			progress?.totalUnitCount = archive.totalUnitCount(addingItem: source)
			try archive.addEntry(at: source, entryPath: source.lastPathComponent, by: level, progress: progress)
		}
	}
	
	/// Unzips the contents at the specified source URL to the destination URL.
	///
	/// - Parameters:
	///   - source: The file URL pointing to an existing ZIP file.
	///   - destination: The file URL that identifies the destination of the unzip operation.
	///   - progress: A progress object that can be used to track or cancel the unzip operation.
	/// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
	@available(iOS 9.0, *)
	public static func unzipItem(at source: URL, to destination: URL, progress: Progress? = nil) throws {
		let archive = try ZipArchive(url: source, for: .read)
		// Defer extraction of symlinks until all files & directories have been created.
		// This is necessary because we can't create links to files that haven't been created yet.
		let sortedEntries = archive.sorted { (left, right) -> Bool in
			switch (left.type, right.type) {
			case (.directory, .file):		return true
			case (.directory, .symlink):	return true
			case (.file, .symlink):			return true
			default:
				return false
			}
		}
		if let progress = progress {
			progress.totalUnitCount = sortedEntries.reduce(Int64(0), {$0 + archive.totalUnitCount(reading: $1)})
		}
		for entry in sortedEntries {
			let destEntry = destination.appendingPathComponent(entry.path)
			if let progress = progress {
				let entryProgress = archive.makeProgress(reading: entry)
				progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
				_ = try archive.extract(entry, to: destEntry, progress: entryProgress)
			} else {
				_ = try archive.extract(entry, to: destEntry)
			}
		}
	}
	
	// MARK: - Helpers
	
	static func typeForItem(at url: URL, with fileManager: FileManager) throws -> ZipEntry.EntryType {
		guard fileManager.fileExists(atPath: url.path) else {
			throw AttributedError(.fileNotFound, userInfo: [NSFilePathErrorKey: url.path])
		}
		let representation = fileManager.fileSystemRepresentation(withPath: url.path)
		var fileStat = stat()
		lstat(representation, &fileStat)
		return ZipEntry.EntryType(mode: fileStat.st_mode)
	}
}

extension Date {
	
	var zipFileModificationDate: UInt16 {
		var time = time_t(timeIntervalSince1970)
		guard let unixTime = gmtime(&time) else {
			return 0
		}
		// UNIX time structs count in "years since 1900".
		// ZIP uses the MSDOS date format which has a valid range of 1980 - 2099.
		let year = min(2099, max(1980, unixTime.pointee.tm_year + 1900))
		// UNIX time struct month entries are zero based.
		return UInt16(unixTime.pointee.tm_mday + (unixTime.pointee.tm_mon + 1) * 32 + (year - 1980) * 512)
	}
	
	var zipFileModificationTime: UInt16 {
		var time = time_t(timeIntervalSince1970)
		guard let unixTime = gmtime(&time) else {
			return 0
		}
		return UInt16(unixTime.pointee.tm_sec / 2 + unixTime.pointee.tm_min * 32 + unixTime.pointee.tm_hour * 2048)
	}
}
