import Dependencies
import Foundation
import Network

/// Broadcasts analytics events and console logs to the Releasy instances found on the local network.
///
/// Each payload is a JSON object (protocol version 1) terminated by a `\0` byte, sent over TCP to
/// every `_releasy._tcp` Bonjour service.
public actor ReleasySender {
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid

  /// The number of payloads kept while no Releasy is connected, so that the logs emitted at launch,
  /// before the browser finds a Releasy, are not lost. The oldest are dropped first.
  static let pendingCapacity = 500

  public let id: String = "AnalyticReleasySender"
  private let encoder = JSONEncoder()
  private var browser: NWBrowser?
  private var connections = [NWEndpoint: NWConnection]()
  private var readyEndpoints = Set<NWEndpoint>()
  private var pending = [Data]()

  public init() {
    Task { await setupBrowser() }
  }

  private func send(_ payload: ReleasyPayload) {
    guard let data = try? encoder.encode(payload) else { return }
    let frame = data + Data([0x00])
    guard !readyEndpoints.isEmpty else {
      pending.append(frame)
      if pending.count > Self.pendingCapacity {
        pending.removeFirst(pending.count - Self.pendingCapacity)
      }
      return
    }
    for endpoint in readyEndpoints {
      connections[endpoint].map { send(frame, on: $0) }
    }
  }

  private func send(_ frame: Data, on connection: NWConnection) {
    connection.send(content: frame, completion: .contentProcessed({ error in
      if let error {
        print("Send data failed with \(error)")
      }
    }))
  }

  private func setupBrowser() {
    let browser = NWBrowser(for: .bonjour(type: "_releasy._tcp", domain: nil), using: .tcp)
    browser.stateUpdateHandler = { [weak self] newState in
      Task { [weak self] in await self?.browserStateChanged(newState: newState) }
    }
    browser.browseResultsChangedHandler = { [weak self] _, changes in
      Task { [weak self] in await self?.browseResultsChanged(changes: changes) }
    }
    browser.start(queue: .main)
    self.browser = browser
  }

  private func browserStateChanged(newState: NWBrowser.State) {
    switch newState {
    case .failed(let error):
      browser?.cancel()
      if error == NWError.dns(DNSServiceErrorType(kDNSServiceErr_DefunctConnection)) {
        setupBrowser()
      }
    case .cancelled: browser = .none
    default: break
    }
  }

  private func browseResultsChanged(changes: Set<NWBrowser.Result.Change>) {
    for change in changes {
      switch change {
      case .added(let result):
        connect(to: result.endpoint)
      case .removed(let result):
        disconnect(from: result.endpoint)
      default: break
      }
    }
  }

  private func connect(to endpoint: NWEndpoint) {
    guard connections[endpoint] == nil else { return }
    let connection = NWConnection(to: endpoint, using: .tcp)
    connections[endpoint] = connection
    // The handler captures the endpoint rather than the connection: capturing the connection inside
    // its own `stateUpdateHandler` retains it forever.
    connection.stateUpdateHandler = { [weak self] newState in
      Task { [weak self] in await self?.connectionStateChanged(newState: newState, endpoint: endpoint) }
    }
    connection.start(queue: .main)
  }

  private func disconnect(from endpoint: NWEndpoint) {
    readyEndpoints.remove(endpoint)
    connections.removeValue(forKey: endpoint)?.cancel()
  }

  private func connectionStateChanged(newState: NWConnection.State, endpoint: NWEndpoint) {
    switch newState {
    case .ready:
      guard let connection = connections[endpoint] else { return }
      readyEndpoints.insert(endpoint)
      pending.forEach { send($0, on: connection) }
      pending.removeAll()
    case .failed(let error):
      print("Connection failed with \(error)")
      disconnect(from: endpoint)
    case .cancelled:
      disconnect(from: endpoint)
    default: break
    }
  }
}

extension ReleasySender {
  /// A log as sent to Releasy, in protocol version 1.
  struct ReleasyPayload: Encodable, Sendable {
    enum Content: Sendable {
      case analytics(name: String, params: Codable & Sendable)
      case console(level: String, category: String, method: String, message: String)
    }

    let id: UUID
    let bundleId: String
    let deviceId: String
    let timestamp: TimeInterval
    let buildNumber: String
    let content: Content

    private enum CodingKeys: String, CodingKey {
      case v, kind, id, deviceId, bundleId, buildNumber, timestamp
      case level, category, method, message
      case name, params
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(1, forKey: .v)
      try container.encode(id, forKey: .id)
      try container.encode(deviceId, forKey: .deviceId)
      try container.encode(bundleId, forKey: .bundleId)
      try container.encode(buildNumber, forKey: .buildNumber)
      try container.encode(timestamp, forKey: .timestamp)
      switch content {
      case let .analytics(name, params):
        try container.encode("analytics", forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(params, forKey: .params)
      case let .console(level, category, method, message):
        try container.encode("console", forKey: .kind)
        try container.encode(level, forKey: .level)
        try container.encode(category, forKey: .category)
        try container.encode(method, forKey: .method)
        try container.encode(message, forKey: .message)
      }
    }
  }
}
