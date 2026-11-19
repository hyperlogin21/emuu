import Foundation
import Testing
import EmuuBase
@testable import EmuuMemory

@Suite struct RingBufferTests {
    @Test func overwritesOldest() {
        var rb = RingBuffer<Int>(capacity: 3)
        #expect(rb.first == nil && rb.last == nil)
        for i in 1...5 { rb.append(i) }
        #expect(rb.elements == [3, 4, 5])
        #expect(rb.count == 3)
        #expect(rb.first == 3)
        #expect(rb.last == 5)
        var seen: [Int] = []
        rb.forEach { seen.append($0) }
        #expect(seen == [3, 4, 5])
        rb.removeAll()
        #expect(rb.isEmpty)
        rb.append(9)
        #expect(rb.elements == [9])
    }

    @Test func boundedOverMillionAppends() {
        var rb = RingBuffer<Int>(capacity: 100)
        for i in 0..<1_000_000 { rb.append(i) }
        #expect(rb.count == 100)
        #expect(rb.first == 999_900)
        #expect(rb.last == 999_999)
    }
}

@Suite struct TrendTests {
    @Test func ewmaConverges() {
        var e = EWMA(timeConstant: .seconds(60))
        #expect(e.add(0, at: .seconds(0)) == 0)
        let v = e.add(100, at: .seconds(60))
        #expect(abs(v - 100 * (1 - exp(-1))) < 1e-9)
        for i in 2...20 { e.add(100, at: .seconds(60 * i)) }
        #expect(abs(e.value! - 100) < 0.01)
    }

    @Test func exactLinearSlope() throws {
        var w = TrendWindow(capacity: 100, minSpacing: .seconds(60))
        for m in 0..<120 { w.add(1000 + Double(m) * 10, at: .seconds(m * 60)) } // +10 per minute = 600/h
        let fit = try #require(w.fit())
        #expect(abs(fit.slopePerHour - 600) < 1e-6)
        #expect(fit.r2 > 0.999)
        #expect(w.count == 100) // bounded
        #expect(fit.span == .seconds(99 * 60))
    }

    @Test func downsamplesAndRejectsFlatOrTiny() {
        var w = TrendWindow(capacity: 10, minSpacing: .seconds(60))
        let kept = w.add(1, at: .seconds(0))
        let dropped = w.add(2, at: .seconds(30))
        #expect(kept)
        #expect(!dropped)
        #expect(w.fit() == nil)
        for m in 1...5 { w.add(5, at: .seconds(m * 60)) }
        let flat = w.fit()
        #expect(flat != nil)
        #expect(flat!.r2 == 0 || abs(flat!.slopePerHour) < 300)
    }

    @Test func noisyDataHasLowR2() throws {
        var w = TrendWindow(capacity: 200, minSpacing: .seconds(1))
        for i in 0..<200 { w.add(i % 2 == 0 ? 0 : 1_000_000, at: .seconds(i * 60)) }
        let fit = try #require(w.fit())
        #expect(fit.r2 < 0.05)
    }
}
