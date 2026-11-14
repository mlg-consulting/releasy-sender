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
    var history = History<Int>(capacity: 3)
    for element in 1...5 {
      history.append(element)
    }

    #expect(history.elements == [3, 4, 5])
  }
}

@Suite struct ReleasyPairingTests {
  @Test func readsPairingLink() throws {
    let url = try #require(URL(string: "releasy-com.app://pair?mac=8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D&secret=a-b_c&name=iPhone%20QA%201"))
    let pairing = try #require(ReleasyPairing(url: url))

    #expect(pairing.macId == "8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D")
    #expect(pairing.secret == "a-b_c")
    #expect(pairing.deviceName == "iPhone QA 1")
  }

  @Test func urlSchemeFollowsBundleIdentifier() {
    #expect(ReleasyPairing.urlScheme(bundleId: "com.Pictarine.photo-print") == "releasy-com.pictarine.photo-print")
  }

  @Test(arguments: [
    "releasy-com.app://pair?mac=mac&name=name",
    "releasy-com.app://pair?secret=secret&name=name",
    "releasy-com.app://pair?mac=&secret=secret&name=name",
    "releasy-com.app://pair?mac=mac&secret=secret",
    "releasy-com.app://pair?mac=mac&secret=secret&name=",
    "releasy-com.app://other?mac=mac&secret=secret&name=name",
    "picta://pair?mac=mac&secret=secret&name=name",
    "https://example.com"
  ])
  func ignoresOtherLinks(link: String) throws {
    let url = try #require(URL(string: link))

    #expect(ReleasyPairing(url: url) == nil)
  }
}

@Suite struct ReleasyPayloadTests {
  let payload = ReleasySender.ReleasyPayload(
    id: UUID(uuidString: "8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D")!,
    bundleId: "com.app",
    deviceId: "device",
    modelName: "iPhone17,1",
    systemVersion: "26.1",
    timestamp: 0,
    buildNumber: "42",
    content: .console(level: "info", category: "", method: "", message: "Hello")
  )

  @Test func encodesDeviceNameWhenPaired() throws {
    var named = payload
    named.deviceName = "iPhone QA 1"

    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(named)) as? [String: Any])

    #expect(json["deviceName"] as? String == "iPhone QA 1")
    #expect(json["user"] == nil)
  }

  @Test func leavesDeviceNameOutWhenUnpaired() throws {
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])

    #expect(json["deviceName"] == nil)
  }
}
