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

@Suite struct ReleasyMessageTests {
  let device = ReleasyDevice(
    deviceId: "device",
    bundleId: "com.app",
    buildNumber: "42",
    modelName: "iPhone17,1",
    systemVersion: "26.1"
  )

  func json(_ message: some Encodable) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
  }

  @Test func logCarriesTheApplicationButNotTheDeviceDescription() throws {
    let payload = ReleasySender.ReleasyPayload(
      id: UUID(uuidString: "8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D")!,
      timestamp: 3,
      content: .console(level: "info", category: "Network", method: "fetch()", message: "Hello")
    )

    let json = try json(LogMessage(payload: payload, device: device))

    #expect(json["kind"] as? String == "console")
    #expect(json["id"] as? String == "8A1F0C55-9D2E-4B7A-A3C1-1E2F3A4B5C6D")
    #expect(json["deviceId"] as? String == "device")
    #expect(json["bundleId"] as? String == "com.app")
    #expect(json["buildNumber"] as? String == "42")
    #expect(json["message"] as? String == "Hello")
    for key in ["modelName", "systemVersion", "deviceName", "user"] {
      #expect(json[key] == nil)
    }
  }

  @Test func helloDescribesTheDevice() throws {
    let json = try json(HelloMessage(device: device, deviceName: "iPhone QA 1", timestamp: 10))

    #expect(json["v"] as? Int == 1)
    #expect(json["kind"] as? String == "hello")
    #expect(json["deviceId"] as? String == "device")
    #expect(json["bundleId"] as? String == "com.app")
    #expect(json["buildNumber"] as? String == "42")
    #expect(json["modelName"] as? String == "iPhone17,1")
    #expect(json["systemVersion"] as? String == "26.1")
    #expect(json["deviceName"] as? String == "iPhone QA 1")
    #expect(json["timestamp"] as? Double == 10)
  }
}

@Suite struct SendQueueTests {
  private func frame(_ byte: UInt8, size: Int = 10) -> Data {
    Data(repeating: byte, count: size)
  }

  @Test func handsFramesToTheConnectionUpToTheInFlightLimit() {
    var queue = SendQueue(maximumInFlightBytes: 20, maximumPendingBytes: 100)

    #expect(queue.enqueue(frame(1)) == [frame(1)])
    #expect(queue.enqueue(frame(2)) == [frame(2)])
    // The connection holds 20 bytes it hasn't processed: the next frame waits.
    #expect(queue.enqueue(frame(3)) == [])
    #expect(queue.pendingBytes == 10)

    #expect(queue.processed(byteCount: 10) == [frame(3)])
    #expect(queue.inFlightBytes == 20)
    #expect(queue.pendingBytes == 0)
  }

  @Test func dropsTheOldestWaitingFramesBeyondThePendingLimit() {
    var queue = SendQueue(maximumInFlightBytes: 10, maximumPendingBytes: 20)

    #expect(queue.enqueue(frame(1)) == [frame(1)])
    for byte in UInt8(2)...5 {
      #expect(queue.enqueue(frame(byte)) == [])
    }
    #expect(queue.pendingBytes == 20)

    // Frames 2 and 3 were dropped: the latest ones are sent once the connection catches up.
    #expect(queue.processed(byteCount: 10) == [frame(4)])
    #expect(queue.processed(byteCount: 10) == [frame(5)])
    #expect(queue.processed(byteCount: 10) == [])
    #expect(queue.inFlightBytes == 0)
  }

  @Test func sendsALargeFrameWhenTheConnectionIsIdle() {
    var queue = SendQueue(maximumInFlightBytes: 10, maximumPendingBytes: 20)

    #expect(queue.enqueue(frame(1, size: 50)) == [frame(1, size: 50)])
    // Waiting, a frame larger than the pending limit can't be kept.
    #expect(queue.enqueue(frame(2, size: 50)) == [])
    #expect(queue.pendingBytes == 0)
  }
}
