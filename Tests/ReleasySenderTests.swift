//
//  ReleasySenderTests.swift
//  releasy-sender
//
//  Created by Loïc Griffé on 13/11/2026.
//

import Foundation
import Testing
@testable import ReleasySender

@Suite struct ReleasySenderTests {
  @Test func retryDelayDoublesUpToThirtySeconds() {
    let delays = (1...8).map { ReleasySender.retryDelay(afterFailedAttempts: $0) }

    #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
  }

  @Test func retryDelayStartsAtOneSecond() {
    #expect(ReleasySender.retryDelay(afterFailedAttempts: 0) == 1)
  }

  @Test func historyKeepsTheLatestFramesInOrder() {
    var history = History(capacity: 3)
    for byte in UInt8(1)...5 {
      history.append(Data([byte]))
    }

    #expect(history.frames == [Data([3]), Data([4]), Data([5])])
  }
}

@Suite struct ReleasyPairingTests {
  @Test func readsPairingLink() throws {
    let url = try #require(URL(string: "releasy://pair?mac=8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D&secret=a-b_c"))
    let pairing = try #require(ReleasyPairing(url: url))

    #expect(pairing.macId == "8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D")
    #expect(pairing.secret == "a-b_c")
  }

  @Test(arguments: [
    "releasy://pair?mac=mac",
    "releasy://pair?secret=secret",
    "releasy://pair?mac=&secret=secret",
    "releasy://other?mac=mac&secret=secret",
    "https://example.com"
  ])
  func ignoresOtherLinks(link: String) throws {
    let url = try #require(URL(string: link))

    #expect(ReleasyPairing(url: url) == nil)
  }
}
