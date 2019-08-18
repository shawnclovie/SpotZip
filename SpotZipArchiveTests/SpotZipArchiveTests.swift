//
//  SpotZipArchiveTests.swift
//  SpotZipArchiveTests
//
//  Created by Shawn Clovie on 18/8/2019.
//  Copyright © 2019 Spotlit.club. All rights reserved.
//

import XCTest
@testable import SpotZipArchive

private let zipFile = "test_compress.txt"

class SpotZipArchiveTests: XCTestCase {

    override func setUp() {
    }

    override func tearDown() {
    }

	func testZip() {
		let zipContent = "1234567890abcdefghijklmnopqrstuvwxyz\n中文😀こんにちは"
		let path = URL.spot_cachesPath.appendingPathComponent(zipFile)
		try! zipContent.write(to: path, atomically: true, encoding: .utf8)
		defer {try? FileManager.default.removeItem(at: path)}
		
		let pathZip = path.appendingPathExtension("zip")
		defer {try? FileManager.default.removeItem(at: pathZip)}
		do {
			if pathZip.spot.fileExists() {
				try FileManager.default.removeItem(at: pathZip)
			}
			let zip = try ZipArchive(url: pathZip, for: .create)
			try zip.addEntry(at: path)
			try zip.addEntry(at: path, entryPath: "1/_\(path.lastPathComponent)")
			print("files in zip:", zip.map{$0.path})
			try FileManager.default.removeItem(at: path)
			try zip.extract(zip[path.lastPathComponent]!, to: path)
			let unzipContent = try String(contentsOf: path)
			print("unzipped file content:", unzipContent)
			XCTAssert(unzipContent == zipContent)
		} catch {
			XCTFail("\(error)")
		}
		let pathConv = pathZip.appendingPathExtension("conv")
		defer {try? FileManager.default.removeItem(at: pathConv)}
		do {
			if pathConv.spot.fileExists() {
				try FileManager.default.removeItem(at: pathConv)
			}
			try ZipArchive.zipItem(at: pathZip, to: pathConv)
			try FileManager.default.removeItem(at: pathZip)
			try ZipArchive.unzipItem(at: pathConv, to: pathZip.deletingLastPathComponent())
		} catch {
			XCTFail("\(error)")
		}
	}
}
