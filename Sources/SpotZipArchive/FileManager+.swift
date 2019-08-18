//
//  FileManager+.swift
//  Spot
//
//  Created by Shawn Clovie on 18/7/2018.
//  Copyright © 2018 Shawn Clovie. All rights reserved.
//

import Foundation
import Spot

extension FileManager {
	
	func createDirectoryIfNotExists(for url: URL) throws {
		guard !fileExists(atPath: url.path) else {return}
		try createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
	}
	
	func permissionsForItem(at URL: URL) throws -> UInt16 {
		let entryFileSystemRepresentation = fileSystemRepresentation(withPath: URL.path)
		var fileStat = stat()
		lstat(entryFileSystemRepresentation, &fileStat)
		return UInt16(fileStat.st_mode)
	}
	
	func fileSizeForItem(at url: URL) throws -> UInt32 {
		guard fileExists(atPath: url.path) else {
			throw AttributedError(.fileNotFound, userInfo: [NSFilePathErrorKey: url.path])
		}
		let representation = fileSystemRepresentation(withPath: url.path)
		var _stat = stat()
		lstat(representation, &_stat)
		return UInt32(_stat.st_size)
	}
	
	func fileModificationDateTimeForItem(at url: URL) throws -> Date {
		guard fileExists(atPath: url.path) else {
			throw AttributedError(.fileNotFound, userInfo: [NSFilePathErrorKey: url.path])
		}
		let representation = fileSystemRepresentation(withPath: url.path)
		var fileStat = stat()
		lstat(representation, &fileStat)
		let modTime = fileStat.st_mtimespec
		let time = TimeInterval(modTime.tv_sec) + TimeInterval(modTime.tv_nsec) / 1_000_000_000
		return Date(timeIntervalSince1970: time)
	}
}
