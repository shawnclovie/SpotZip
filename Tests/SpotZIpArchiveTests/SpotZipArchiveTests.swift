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
		let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent(zipFile)
		try! zipContent.write(to: path, atomically: true, encoding: .utf8)
		defer {try? FileManager.default.removeItem(at: path)}
		
		let pathZip = path.appendingPathExtension("zip")
		defer {try? FileManager.default.removeItem(at: pathZip)}
		do {
			if FileManager.default.fileExists(atPath: pathZip.path) {
				try FileManager.default.removeItem(at: pathZip)
			}
			let zip = try ZipArchive(path: pathZip, mode: .create)
			try zip.addEntry(at: path)
			try zip.addEntry(at: path, entryPath: "1/_\(path.lastPathComponent)")
			print("files in zip:", zip.map{$0.path})
			try FileManager.default.removeItem(at: path)
			try zip.extract(zip[path.lastPathComponent]!, targetPath: path)
			let unzipContent = try String(contentsOf: path)
			print("unzipped file content:", unzipContent)
			XCTAssert(unzipContent == zipContent)
		} catch {
			XCTFail("\(error)")
		}
		let pathConv = pathZip.appendingPathExtension("conv")
		defer {try? FileManager.default.removeItem(at: pathConv)}
		do {
			if FileManager.default.fileExists(atPath: pathConv.path) {
				try FileManager.default.removeItem(at: pathConv)
			}
			try ZipArchive.zipItem(path: pathZip, destination: pathConv)
			try FileManager.default.removeItem(at: pathZip)
			try ZipArchive.unzipItem(path: pathConv, destination: pathZip.deletingLastPathComponent())
		} catch {
			XCTFail("\(error)")
		}
	}
}
