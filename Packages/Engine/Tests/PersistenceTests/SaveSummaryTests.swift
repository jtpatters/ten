import Foundation
import Testing
import GameCore
import Persistence

@Suite struct SaveSummaryTests {
    /// A save's header leaves its file's URL out; decoding takes the URL from the decoder.
    @Test func headerRoundTripLeavesTheURLOut() throws {
        let url = URL(fileURLWithPath: "/tmp/Saves/auto-12-0-1.ttys")
        let summary = SaveSummary(url: url, name: "Rome – Turn 12", kind: .auto, savedAt: Date(timeIntervalSinceReferenceDate: 0),
                                  turn: 12, currentPlayer: PlayerID(0), civName: "Rome", mapSizeName: "duel", seed: 7, rulesID: "m1.0")
        let header = try JSONEncoder().encode(summary)
        #expect(!String(decoding: header, as: UTF8.self).contains("auto-12-0-1"))

        let decoder = JSONDecoder()
        decoder.userInfo[SaveSummary.fileURLKey] = url
        #expect(try decoder.decode(SaveSummary.self, from: header) == summary)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SaveSummary.self, from: header) }
    }
}
