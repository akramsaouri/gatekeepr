import CZlib
import Foundation

enum Gzip {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Decompresses gzip data, including files made of several gzip members.
    /// zlib checks each member's CRC and length, so corruption is an error.
    static func decompress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }

        var stream = z_stream()
        // 15 window bits + 16 means "expect a gzip header and trailer".
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure(description: "zlib failed to initialise")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 256 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()

        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            let base = input.bindMemory(to: Bytef.self).baseAddress!
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)

            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    output.append(buffer.baseAddress!, count: chunkSize - Int(stream.avail_out))
                    return status
                }
                switch status {
                case Z_STREAM_END:
                    let remaining = Int(stream.avail_in)
                    // Some tools pad the end of a file with zeros; anything else
                    // left over is the next gzip member.
                    if remaining == 0 || input.suffix(remaining).allSatisfy({ $0 == 0 }) {
                        return
                    }
                    inflateReset(&stream)
                case Z_OK:
                    continue
                case Z_BUF_ERROR where stream.avail_in == 0:
                    throw Failure(description: "gzip data is truncated")
                default:
                    let message = stream.msg.map { String(cString: $0) } ?? "zlib error \(status)"
                    throw Failure(description: "gzip data is corrupt (\(message))")
                }
            }
        }
        return output
    }
}
