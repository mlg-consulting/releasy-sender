import Dependencies
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Sends analytics events and console logs to the Releasy the application is paired with, found on
/// the local network.
///
/// Nothing is sent until `pair(with:)` receives the pairing Releasy shows as a QR code (see
/// `ReleasyPairing`). Each payload
/// is then a JSON object (protocol version 1) terminated by a `\0` byte, sent over TLS with the
/// pairing's pre-shared key to the `_releasy._tcp` Bonjour service advertising the paired Mac.
public actor ReleasySender {
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid

  /// The number of latest payloads kept and sent again to every Releasy that connects. The oldest
  /// are dropped first.
  ///
  /// This covers the logs emitted before a Releasy is found, at launch, and those lost on a
  /// connection that died before it was detected. Releasy ignores the logs it already received,
  /// by their identifier.
  static let historyCapacity = 500

  /// The longest wait between two connection attempts to a Releasy, in seconds.
  static let maximumRetryDelay: TimeInterval = 30

  /// The user defaults key the pairing is stored under.
  static let pairingKey = "releasy.pairing"

  /// A connection to a Releasy, identified so that the events of a connection that was replaced,
  /// such as the `.cancelled` state that follows its cancellation, are ignored.
  private struct Link {
    let id: UUID
    let connection: NWConnection
  }

  private let encoder = JSONEncoder()
  /// The queue the browser and the connections deliver their events on, off the main thread so
  /// that sending logs doesn't take time from the application's interface.
  private let queue = DispatchQueue(label: "com.releasy.sender", qos: .utility)
  private var browser: NWBrowser?
  /// The Releasy the application is paired with, kept across launches. `nil` until paired.
  public private(set) var pairing: ReleasyPairing? = ReleasySender.storedPairing()
  /// The identifier of the Mac each Releasy advertised on the network runs on.
  private var advertisedMacIds = [NWEndpoint: String]()
  /// The advertised Releasy instances running on the paired Mac: the only ones connected to.
  private var advertisedEndpoints = Set<NWEndpoint>()
  private var links = [NWEndpoint: Link]()
  private var readyEndpoints = Set<NWEndpoint>()
  /// The number of failed attempts in a row, for each Releasy, which sets the delay before the next one.
  private var failedAttempts = [NWEndpoint: Int]()
  private var retryTasks = [NWEndpoint: Task<Void, Never>]()
  private var history = History(capacity: historyCapacity)

  public init() {
    Task {
      await setupBrowser()
      await observeForeground()
    }
  }

  /// Pairs the application with the Releasy that showed `pairing`, and connects to it. The
  /// connections to a Releasy paired before are closed.
  public func pair(with pairing: ReleasyPairing) {
    self.pairing = pairing
    UserDefaults.standard.set(try? JSONEncoder().encode(pairing), forKey: Self.pairingKey)
    restartConnections()
  }

  /// Stops sending to the paired Releasy.
  public func unpair() {
    pairing = .none
    UserDefaults.standard.removeObject(forKey: Self.pairingKey)
    restartConnections()
  }

  public func send(_ payload: ReleasyPayload) {
    guard let data = try? encoder.encode(payload) else { return }
    let frame = data + Data([0x00])
    history.append(frame)
    for endpoint in readyEndpoints {
      links[endpoint].map { send(frame, on: $0.connection) }
    }
  }

  public func send(_ frame: Data, on connection: NWConnection) {
    connection.send(content: frame, completion: .contentProcessed({ error in
      if let error {
        print("Send data failed with \(error)")
      }
    }))
  }

  /// The wait before the attempt following `failedAttempts` failures in a row, in seconds: 1, 2,
  /// 4, 8 and 16 seconds, then 30 seconds.
  static func retryDelay(afterFailedAttempts failedAttempts: Int) -> TimeInterval {
    let seconds = TimeInterval(1 << min(max(failedAttempts - 1, 0), 5))
    return min(seconds, maximumRetryDelay)
  }

  // MARK: - Browsing

  private func setupBrowser() {
    let parameters = NWParameters.tcp
    // Also find a Releasy over a direct iPhone–Mac link (AWDL), when they share no Wi-Fi network.
    parameters.includePeerToPeer = true
    // The TXT record tells which Mac each Releasy runs on.
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_releasy._tcp", domain: nil), using: parameters)
    browser.stateUpdateHandler = { [weak self] newState in
      Task { [weak self] in await self?.browserStateChanged(newState: newState) }
    }
    browser.browseResultsChangedHandler = { [weak self] _, changes in
      Task { [weak self] in await self?.browseResultsChanged(changes: changes) }
    }
    browser.start(queue: queue)
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
      case .added(let result), .changed(_, let result, _):
        if case .bonjour(let txtRecord) = result.metadata, let macId = txtRecord["id"] {
          advertisedMacIds[result.endpoint] = macId
        } else {
          advertisedMacIds.removeValue(forKey: result.endpoint)
        }
        refresh(result.endpoint)
      case .removed(let result):
        advertisedMacIds.removeValue(forKey: result.endpoint)
        refresh(result.endpoint)
      default: break
      }
    }
  }

  /// Connects to an advertised Releasy running on the paired Mac, and forgets any other.
  private func refresh(_ endpoint: NWEndpoint) {
    if let pairing, advertisedMacIds[endpoint] == pairing.macId {
      advertisedEndpoints.insert(endpoint)
      connect(to: endpoint)
    } else {
      advertisedEndpoints.remove(endpoint)
      forget(endpoint)
    }
  }

  /// Closes every connection, which uses the previous pairing, and connects again with the current one.
  private func restartConnections() {
    for endpoint in Set(links.keys).union(retryTasks.keys) {
      forget(endpoint)
    }
    advertisedEndpoints.removeAll()
    advertisedMacIds.keys.forEach(refresh)
  }

  // MARK: - Connections

  private func connect(to endpoint: NWEndpoint) {
    guard links[endpoint] == nil, advertisedEndpoints.contains(endpoint), let pairing else { return }
    let id = uuid()
    let connection = NWConnection(to: endpoint, using: .releasy(pairing: pairing))
    links[endpoint] = Link(id: id, connection: connection)
    // The handler captures the endpoint and the id rather than the connection: capturing the
    // connection inside its own `stateUpdateHandler` retains it forever.
    connection.stateUpdateHandler = { [weak self] newState in
      Task { [weak self] in await self?.connectionStateChanged(newState: newState, endpoint: endpoint, id: id) }
    }
    connection.start(queue: queue)
  }

  /// Closes the connection to `endpoint`, if any, without retrying.
  private func disconnect(from endpoint: NWEndpoint) {
    readyEndpoints.remove(endpoint)
    links.removeValue(forKey: endpoint)?.connection.cancel()
  }

  /// Closes the connection to a Releasy that is no longer advertised, and stops retrying it.
  private func forget(_ endpoint: NWEndpoint) {
    disconnect(from: endpoint)
    retryTasks.removeValue(forKey: endpoint)?.cancel()
    failedAttempts.removeValue(forKey: endpoint)
  }

  private func connectionStateChanged(newState: NWConnection.State, endpoint: NWEndpoint, id: UUID) {
    guard let link = links[endpoint], link.id == id else { return }
    switch newState {
    case .ready:
      readyEndpoints.insert(endpoint)
      failedAttempts.removeValue(forKey: endpoint)
      history.frames.forEach { send($0, on: link.connection) }
    case .failed(let error):
      print("Connection failed with \(error)")
      retry(endpoint)
    case .waiting(let error):
      // A waiting connection only tries again when the network changes, which may never happen
      // while the Releasy is reachable again: retry on schedule instead.
      print("Connection waiting with \(error)")
      retry(endpoint)
    case .cancelled:
      disconnect(from: endpoint)
    default: break
    }
  }

  /// Closes the connection to `endpoint` and schedules a new attempt, for as long as the Releasy is
  /// advertised.
  private func retry(_ endpoint: NWEndpoint) {
    disconnect(from: endpoint)
    guard advertisedEndpoints.contains(endpoint), retryTasks[endpoint] == nil else { return }
    let attempts = failedAttempts[endpoint, default: 0] + 1
    failedAttempts[endpoint] = attempts
    let delay = Self.retryDelay(afterFailedAttempts: attempts)
    retryTasks[endpoint] = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      } catch {
        return // Cancelled: the Releasy is no longer advertised.
      }
      await self?.retryDelayElapsed(for: endpoint)
    }
  }

  private func retryDelayElapsed(for endpoint: NWEndpoint) {
    retryTasks.removeValue(forKey: endpoint)
    connect(to: endpoint)
  }

  // MARK: - Foreground

  /// Reconnects as soon as the application comes back to the foreground: connections opened before
  /// going to the background are usually dead, and the browser may have stopped.
  private func observeForeground() {
#if canImport(UIKit) && !os(watchOS)
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
        guard let self else { return }
        await applicationWillEnterForeground()
      }
    }
#endif
  }

  private func applicationWillEnterForeground() {
    guard browser != nil else {
      // The browser stopped, so the advertised instances may be stale: start over from what a new
      // browser finds, which it reports as added.
      advertisedEndpoints.forEach(forget)
      advertisedEndpoints.removeAll()
      advertisedMacIds.removeAll()
      setupBrowser()
      return
    }
    for endpoint in advertisedEndpoints where !readyEndpoints.contains(endpoint) {
      retryTasks.removeValue(forKey: endpoint)?.cancel()
      failedAttempts.removeValue(forKey: endpoint)
      disconnect(from: endpoint)
      connect(to: endpoint)
    }
  }
}

extension ReleasySender {
  private static func storedPairing() -> ReleasyPairing? {
    UserDefaults.standard.data(forKey: pairingKey).flatMap { try? JSONDecoder().decode(ReleasyPairing.self, from: $0) }
  }
}

/// The latest frames, in sending order, up to a capacity: the oldest are dropped first.
struct History {
  let capacity: Int
  private(set) var frames: [Data] = []

  init(capacity: Int) {
    self.capacity = capacity
  }

  mutating func append(_ frame: Data) {
    frames.append(frame)
    if frames.count > capacity {
      frames.removeFirst(frames.count - capacity)
    }
  }
}

extension NWParameters {
  /// TLS-PSK parameters with the pairing's key, and TCP parameters that notice a vanished Releasy,
  /// such as a Mac gone to sleep or off the network, instead of keeping a dead connection.
  static func releasy(pairing: ReleasyPairing) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    // Send each small log right away rather than waiting to batch it.
    tcp.noDelay = true
    // Give up on a Releasy that doesn't answer within 10 seconds.
    tcp.connectionTimeout = 10
    // Drop the connection when sent logs stay unacknowledged for 15 seconds: the keepalive below
    // only probes an idle connection, and the application keeps sending.
    tcp.connectionDropTime = 15
    // Probe an idle connection after 10 seconds, then every 5 seconds, and drop it after 3 probes
    // without answer, about 25 seconds in all.
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3
    let parameters = NWParameters(tls: pairing.tlsOptions, tcp: tcp)
    // Reach a Releasy found over a direct iPhone–Mac link (AWDL) as well as over the Wi-Fi network.
    parameters.includePeerToPeer = true
    return parameters
  }
}

extension ReleasySender {
  /// A log as sent to Releasy, in protocol version 1.
  public struct ReleasyPayload: Encodable, Sendable {
    public enum Content: Sendable {
      case analytics(name: String, params: Codable & Sendable)
      case console(level: String, category: String, method: String, message: String)
    }

    let id: UUID
    let bundleId: String
    let modelName: String
    let systemVersion: String
    let deviceId: String
    let timestamp: TimeInterval
    let buildNumber: String
    let user: String
    let content: Content

    public init(
      id: UUID,
      bundleId: String,
      deviceId: String,
      modelName: String,
      systemVersion: String,
      timestamp: TimeInterval,
      buildNumber: String,
      user: String,
      content: Content
    ) {
      self.id = id
      self.bundleId = bundleId
      self.deviceId = deviceId
      self.modelName = modelName
      self.systemVersion = systemVersion
      self.timestamp = timestamp
      self.buildNumber = buildNumber
      self.user = user
      self.content = content
    }

    private enum CodingKeys: String, CodingKey {
      case v, kind, id, deviceId, modelName, systemVersion, bundleId, buildNumber, user, timestamp
      case level, category, method, message
      case name, params
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(1, forKey: .v)
      try container.encode(id, forKey: .id)
      try container.encode(deviceId, forKey: .deviceId)
      try container.encode(modelName, forKey: .modelName)
      try container.encode(systemVersion, forKey: .systemVersion)
      try container.encode(bundleId, forKey: .bundleId)
      try container.encode(buildNumber, forKey: .buildNumber)
      try container.encode(user, forKey: .user)
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
