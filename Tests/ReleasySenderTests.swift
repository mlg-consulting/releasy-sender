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
