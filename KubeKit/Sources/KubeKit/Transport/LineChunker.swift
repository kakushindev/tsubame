import Foundation

/// Splits a byte stream into newline-delimited lines, with a bounded buffer.
///
/// This replaces `AsyncLineSequence`, which is wrong here twice over. It treats a
/// bare `\r` as a terminator, so container output carrying a progress bar is split
/// into lines that were never lines; and it buffers a line of unbounded length,
/// which would put the growth *below* any limit the log layer sets and make that
/// limit fiction.
///
/// So: split on `0x0A` and nothing else, and force-break a line that outgrows
/// `maximumLineLength` rather than buffering it. Because `0x0A` cannot occur inside
/// a multi-byte UTF-8 sequence, splitting on it never divides a character.
/// Force-breaks retain incomplete UTF-8 bytes for the next chunk as well.
struct LineChunker {
    /// The longest line that will be buffered. Beyond this the line is cut and the
    /// remainder continues as the next one.
    let maximumLineLength: Int

    private var buffer = Data()

    init(maximumLineLength: Int) {
        precondition(maximumLineLength > 0, "A line limit of zero would emit nothing but empty lines.")
        self.maximumLineLength = maximumLineLength
    }

    /// Whether a partial line is held. `flush()` is what releases it.
    var hasBufferedBytes: Bool { !buffer.isEmpty }

    /// Appends one byte, returning a line if that byte completed one.
    ///
    /// `URLSession.AsyncBytes` yields bytes, so this is the hot path; it exists to
    /// keep that loop from allocating a `Data` per byte.
    mutating func consume(_ byte: UInt8) -> Data? {
        if byte == 0x0A {
            defer { buffer = Data() }
            return buffer
        }
        buffer.append(byte)
        if buffer.count > maximumLineLength {
            var cut = maximumLineLength
            // A continuation byte belongs to the scalar starting before it.
            // Retain that scalar rather than replacing half of it at decode time.
            while cut > 0, buffer[buffer.startIndex + cut] & 0xC0 == 0x80 { cut -= 1 }
            if cut == 0 { cut = maximumLineLength } // invalid UTF-8 or a limit below one scalar
            let line = Data(buffer.prefix(cut))
            buffer = Data(buffer.dropFirst(cut))
            return line
        }
        return nil
    }

    /// Appends a chunk and returns every line it completed.
    ///
    /// A chunk may complete several lines, part of one, or none at all; the
    /// remainder stays buffered for the next call.
    mutating func consume(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        for byte in chunk {
            if let line = consume(byte) { lines.append(line) }
        }
        return lines
    }

    /// The trailing bytes, for a stream that ended without a final newline.
    mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer = Data() }
        return buffer
    }
}
