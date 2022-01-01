import Foundation
#if os(Linux)
import zlibLinux
#else
import zlib
#endif

public struct ZipError: Error {
	public enum Reason {
		case cancelled, unknown
		case fileNotFound, fileNotAccessable
		
		case invalidFormat

		/// Thrown when an `Entry` can't be stored in the archive with the proposed compression method.
		case invalidArchiveLevel
		
		/// Thrown when the start of the central directory exceeds `UINT32_MAX`
		case invalidStartOfCentralDirectoryOffset
		
		/// The stream structure was inconsistent.
		/// - underlying zlib error: `Z_STREAM_ERROR` (-2)
		case gzipStream
		
		/// The input data was corrupted (input stream not conforming to the zlib format or incorrect check value).
		/// - underlying zlib error: `Z_DATA_ERROR` (-3)
		case gzipData
		
		/// There was not enough memory.
		/// - underlying zlib error: `Z_MEM_ERROR` (-4)
		case gzipMemory
		
		/// No progress is possible or there was not enough room in the output buffer.
		/// - underlying zlib error: `Z_BUF_ERROR` (-5)
		case gzipBuffer
		
		/// The zlib library version is incompatible with the version assumed by the caller.
		/// - underlying zlib error: `Z_VERSION_ERROR` (-6)
		case gzipVersion
	}
	
	public let reason: Reason
	public let description: String
	public let userInfo: [String: Any]
	
	init(_ reason: Reason, _ desc: String = "", userInfo: [String: Any] = [:]) {
		self.reason = reason
		description = desc
		self.userInfo = userInfo
	}
	
	init(gzip code: Int32, _ stream: z_stream) {
		let desc: String
		if let msg = stream.msg, let message = String(validatingUTF8: msg) {
			desc = message
		} else {
			desc = "unknown_gzip_error"
		}
		self.init(Self.gzipReason(code: code), userInfo: [NSLocalizedDescriptionKey: desc, "code": code])
	}
	
	static func gzipReason(code: Int32) -> Reason {
		switch code {
		case Z_STREAM_ERROR:
			return .gzipStream
		case Z_DATA_ERROR:
			return .gzipData
		case Z_MEM_ERROR:
			return .gzipMemory
		case Z_BUF_ERROR:
			return .gzipBuffer
		case Z_VERSION_ERROR:
			return .gzipVersion
		default:
			return .unknown
		}
	}
}
