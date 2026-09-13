import XCTest
@testable import ClarifyKit

final class HeaderTests: XCTestCase {
    func testRoundTripPreservesUserText() {
        let header = Header(["kind": "action", "context": "@phone", "minutes": "10"])
        let notes = header.render(body: "Dr. Patel, 617 555 0100\nsecond line")
        let (parsed, body) = Header.parse(notes)
        XCTAssertEqual(parsed, header)
        XCTAssertEqual(body, "Dr. Patel, 617 555 0100\nsecond line")
    }

    func testNotesWithoutHeaderAreAllBody() {
        let (parsed, body) = Header.parse("just user text")
        XCTAssertNil(parsed)
        XCTAssertEqual(body, "just user text")
    }

    func testApplyRewritesHeaderAndKeepsBody() {
        let original = Header(["kind": "action"]).render(body: "keep me")
        var updated = Header(["kind": "project", "area": "Admin"])
        updated["reason"] = "multi step"
        let notes = updated.apply(to: original)
        let (parsed, body) = Header.parse(notes)
        XCTAssertEqual(parsed?["kind"], "project")
        XCTAssertEqual(parsed?["reason"], "multi step")
        XCTAssertNil(parsed?["minutes"])
        XCTAssertEqual(body, "keep me")
    }

    func testUnknownKeysSurvive() {
        let notes = "--- clarify ---\nkind: action\nmystery: 42\n--- end ---\nbody"
        let (parsed, _) = Header.parse(notes)
        XCTAssertEqual(parsed?["mystery"], "42")
        XCTAssertEqual(parsed?.render(body: ""), "--- clarify ---\nkind: action\nmystery: 42\n--- end ---")
    }

    func testMultilineValuesAreFlattened() {
        let header = Header(["reason": "line one\nline two"])
        let (parsed, _) = Header.parse(header.render(body: ""))
        XCTAssertEqual(parsed?["reason"], "line one line two")
    }

    func testRoundTripInvariantOverRandomKeySets() {
        for seed in 0..<200 {
            var rng = SplitMix(seed: UInt64(seed))
            let count = Int(rng.next() % 6)
            var fields: [(key: String, value: String)] = []
            var used = Set<String>()
            for _ in 0..<count {
                let key = Header.knownKeys[Int(rng.next() % UInt64(Header.knownKeys.count))]
                guard used.insert(key).inserted else { continue }
                fields.append((key: key, value: "v\(rng.next() % 1000)"))
            }
            let body = rng.next() % 2 == 0 ? "" : "user\ntext \(rng.next())"
            let header = Header(fields: fields)
            let (parsed, parsedBody) = Header.parse(header.render(body: body))
            XCTAssertEqual(parsed ?? Header(), header, "seed \(seed)")
            XCTAssertEqual(parsedBody, body, "seed \(seed)")
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
