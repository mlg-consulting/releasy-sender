//
//  ReleasySenderTests.swift
//  releasy-sender
//
//  Created by Loïc Griffé on 13/11/2026.
//

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
}
