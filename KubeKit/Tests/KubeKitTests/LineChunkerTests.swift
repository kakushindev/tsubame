import Foundation
import Testing
@testable import KubeKit

@Suite("LineChunker")
struct LineChunkerTests {
    @Test("Byte and chunk paths bound long terminated lines without splitting UTF-8")
    func boundsLongTerminatedUnicode() {
        let text = String(repeating: "燕abc", count: 2_000)
        var chunker = LineChunker(maximumLineLength: 8192)
        let produced = lines(of: &chunker, feeding: [Data((text + "\n").utf8)])
        #expect(produced.allSatisfy { $0.count <= 8192 })
        #expect(produced.map { String(decoding: $0, as: UTF8.self) }.joined() == text)
    }

    private func lines(of chunker: inout LineChunker, feeding chunks: [Data]) -> [Data] {
        var produced: [Data] = []
        for chunk in chunks { produced.append(contentsOf: chunker.consume(chunk)) }
        if let trailing = chunker.flush() { produced.append(trailing) }
        return produced
    }

    @Test("Splits on newline and drops the terminator")
    func splitsOnNewline() {
        var chunker = LineChunker(maximumLineLength: 1024)
        let produced = lines(of: &chunker, feeding: [Data("one\ntwo\nthree\n".utf8)])
        #expect(produced.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
    }

    @Test("Reassembles a line split across chunk boundaries")
    func reassemblesAcrossChunks() {
        var chunker = LineChunker(maximumLineLength: 1024)
        let produced = lines(of: &chunker, feeding: [
            Data("{\"ty".utf8), Data("pe\":\"ADD".utf8), Data("ED\"}\n".utf8),
        ])
        #expect(produced.map { String(decoding: $0, as: UTF8.self) } == ["{\"type\":\"ADDED\"}"])
    }

    @Test("Keeps a carriage return inside the line instead of splitting on it")
    func doesNotSplitOnCarriageReturn() {
        // The reason AsyncLineSequence was unusable: a progress bar is one line.
        var chunker = LineChunker(maximumLineLength: 1024)
        let produced = lines(of: &chunker, feeding: [Data("50%\r75%\r100%\n".utf8)])
        #expect(produced.count == 1)
        #expect(String(decoding: produced[0], as: UTF8.self) == "50%\r75%\r100%")
    }

    @Test("Emits a trailing line that never got a newline")
    func emitsTrailingPartial() {
        var chunker = LineChunker(maximumLineLength: 1024)
        let produced = lines(of: &chunker, feeding: [Data("no terminator".utf8)])
        #expect(produced.map { String(decoding: $0, as: UTF8.self) } == ["no terminator"])
    }

    @Test("Force-breaks a line that outgrows the limit, so the buffer stays bounded")
    func forceBreaksOversizeLine() {
        var chunker = LineChunker(maximumLineLength: 8)
        let produced = lines(of: &chunker, feeding: [Data(String(repeating: "x", count: 30).utf8)])
        #expect(produced.allSatisfy { $0.count <= 8 })
        #expect(produced.reduce(0) { $0 + $1.count } == 30)
        #expect(!chunker.hasBufferedBytes)
    }

    @Test("A multi-megabyte line with no newline never buffers past the limit")
    func boundsAnUnterminatedFlood() {
        var chunker = LineChunker(maximumLineLength: 1024)
        var emitted: [Data] = []
        for _ in 0..<(4 * 1024) {
            emitted.append(contentsOf: chunker.consume(Data(String(repeating: "y", count: 1024).utf8)))
        }
        // 4 MiB arrived with no terminator: it must have come back out, in pieces
        // no larger than the limit, rather than sitting in the buffer.
        #expect(emitted.allSatisfy { $0.count <= 1024 })
        #expect(emitted.reduce(0) { $0 + $1.count } >= 4 * 1024 * 1024 - 1024)
    }

    @Test("Concatenating the lines with newlines reproduces newline-terminated input")
    func roundTripsArbitraryInput() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let lineCount = Int.random(in: 0...12, using: &generator)
            let original = (0..<lineCount).map { _ -> String in
                String(repeating: "ab\r \u{00e9}", count: Int.random(in: 0...6, using: &generator))
            }
            let text = original.map { $0 + "\n" }.joined()

            var chunker = LineChunker(maximumLineLength: 1 << 20)
            var chunks: [Data] = []
            var remaining = Data(text.utf8)
            while !remaining.isEmpty {
                let size = min(Int.random(in: 1...7, using: &generator), remaining.count)
                chunks.append(remaining.prefix(size))
                remaining = remaining.dropFirst(size)
            }
            let produced = lines(of: &chunker, feeding: chunks)
            #expect(produced.map { String(decoding: $0, as: UTF8.self) } == original)
        }
    }

    @Test("Splitting on 0x0A alone never divides a multi-byte character")
    func preservesMultiByteCharacters() {
        var chunker = LineChunker(maximumLineLength: 1024)
        // Each of these is several bytes, none of which is 0x0A.
        let text = "燕 swallow ✓\nследующий\n"
        var produced: [Data] = []
        for byte in Data(text.utf8) {
            if let line = chunker.consume(byte) { produced.append(line) }
        }
        #expect(produced.map { String(decoding: $0, as: UTF8.self) } == ["燕 swallow ✓", "следующий"])
    }
}
