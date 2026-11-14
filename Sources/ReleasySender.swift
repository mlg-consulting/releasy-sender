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
/// `ReleasyPairing`). Each connection, over TLS with the pairing's pre-shared key to the
/// `_releasy._tcp` Bonjour service advertising the paired Mac, then opens with a `hello` message
/// describing the device, followed by the logs: JSON objects (protocol version 1), each terminated
/// by a `\0` byte.
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
    /// The frames waiting for the connection to process the ones handed to it.
    var sendQueue = SendQueue()
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
  private var history = History<ReleasyPayload>(capacity: historyCapacity)
  private let device: ReleasyDevice

  /// - Parameter device: The device the application runs on, described to Releasy when connecting.
  public init(device: ReleasyDevice) {
    self.device = device
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
    history.append(payload)
    guard let frame = frame(for: payload) else { return }
    for endpoint in readyEndpoints {
      send(frame, to: endpoint)
    }
  }

  private func frame(for payload: ReleasyPayload) -> Data? {
    frame(LogMessage(payload: payload, device: device))
  }

  /// The `hello` message, with the current name of the paired device.
  private func helloFrame() -> Data? {
    frame(HelloMessage(device: device, deviceName: pairing?.deviceName, timestamp: now.timeIntervalSince1970))
  }

  private func frame(_ message: some Encodable) -> Data? {
    guard let data = try? encoder.encode(message) else { return nil }
    return data + Data([0x00])
  }

  /// Queues the frame on the connection to `endpoint`, which receives it once it has processed
  /// enough of the frames handed to it before.
  private func send(_ frame: Data, to endpoint: NWEndpoint) {
    guard let frames = links[endpoint]?.sendQueue.enqueue(frame) else { return }
    write(frames, to: endpoint)
  }

  private func write(_ frames: [Data], to endpoint: NWEndpoint) {
    guard let link = links[endpoint] else { return }
    for frame in frames {
      link.connection.send(content: frame, completion: .contentProcessed({ [weak self, id = link.id] error in
        if let error {
          print("Send data failed with \(error)")
        }
        Task { [weak self] in await self?.frameProcessed(byteCount: frame.count, endpoint: endpoint, id: id) }
      }))
    }
  }

  /// Hands the connection the frames that were waiting for it to process this one.
  private func frameProcessed(byteCount: Int, endpoint: NWEndpoint, id: UUID) {
    guard links[endpoint]?.id == id, let frames = links[endpoint]?.sendQueue.processed(byteCount: byteCount) else { return }
    write(frames, to: endpoint)
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
    guard links[endpoint]?.id == id else { return }
    switch newState {
    case .ready:
      readyEndpoints.insert(endpoint)
      failedAttempts.removeValue(forKey: endpoint)
      // The hello first, so that Releasy describes the logs that follow with it. It is handed to
      // the connection right away, so the history that follows can't push it out of the queue.
      ([helloFrame()] + history.elements.map(frame(for:))).compactMap { $0 }.forEach { send($0, to: endpoint) }
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

/// The latest elements, in sending order, up to a capacity: the oldest are dropped first.
struct History<Element> {
  let capacity: Int
  private(set) var elements: [Element] = []

  init(capacity: Int) {
    self.capacity = capacity
  }

  mutating func append(_ element: Element) {
    elements.append(element)
    if elements.count > capacity {
      elements.removeFirst(elements.count - capacity)
    }
  }
}

/// The frames to send on a connection, bounded so that a Releasy reading slowly doesn't grow the
/// memory of the application without limit.
///
/// `NWConnection.send` queues without limit, and the frames handed to it can't be taken back. So
/// only `maximumInFlightBytes` are handed to the connection until it has processed them, and the
/// following frames wait here, up to `maximumPendingBytes`: beyond it, the oldest are dropped.
struct SendQueue {
  let maximumInFlightBytes: Int
  let maximumPendingBytes: Int
  /// The bytes handed to the connection that it has not processed yet.
  private(set) var inFlightBytes = 0
  /// The bytes of the frames waiting to be handed to the connection.
  private(set) var pendingBytes = 0
  private var pending: [Data] = []

  init(maximumInFlightBytes: Int = 256 * 1024, maximumPendingBytes: Int = 1 << 20) {
    self.maximumInFlightBytes = maximumInFlightBytes
    self.maximumPendingBytes = maximumPendingBytes
  }

  /// Queues the frame, and returns the frames to hand to the connection now, in order.
  mutating func enqueue(_ frame: Data) -> [Data] {
    pending.append(frame)
    pendingBytes += frame.count
    let frames = dequeueReady()
    while pendingBytes > maximumPendingBytes, !pending.isEmpty {
      pendingBytes -= pending.removeFirst().count
    }
    return frames
  }

  /// Records that the connection processed a frame of `byteCount` bytes, and returns the frames to
  /// hand to it now, in order.
  mutating func processed(byteCount: Int) -> [Data] {
    inFlightBytes = max(inFlightBytes - byteCount, 0)
    return dequeueReady()
  }

  private mutating func dequeueReady() -> [Data] {
    var frames: [Data] = []
    while inFlightBytes < maximumInFlightBytes, !pending.isEmpty {
      let frame = pending.removeFirst()
      pendingBytes -= frame.count
      inFlightBytes += frame.count
      frames.append(frame)
    }
    return frames
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
  /// A log as sent to Releasy, in protocol version 1. The device it comes from is described once,
  /// in the `hello` message that opens each connection, rather than in every log.
  public struct ReleasyPayload: Sendable {
    public enum Content: Sendable {
      case analytics(name: String, params: Codable & Sendable)
      case console(level: String, category: String, method: String, message: String)
    }

    let id: UUID
    let timestamp: TimeInterval
    let content: Content

    public init(id: UUID, timestamp: TimeInterval, content: Content) {
      self.id = id
      self.timestamp = timestamp
      self.content = content
    }
  }
}

/// The device the application runs on, described to Releasy when connecting.
public struct ReleasyDevice: Equatable, Sendable {
  /// Identifies the device, such as its `identifierForVendor`.
  public let deviceId: String
  public let bundleId: String
  public let buildNumber: String
  /// The device model identifier, such as `iPhone17,1`.
  public let modelName: String
  public let systemVersion: String

  public init(deviceId: String, bundleId: String, buildNumber: String, modelName: String, systemVersion: String) {
    self.deviceId = deviceId
    self.bundleId = bundleId
    self.buildNumber = buildNumber
    self.modelName = modelName
    self.systemVersion = systemVersion
  }
}

private enum CodingKeys: String, CodingKey {
  case v, kind, id, deviceId, bundleId, buildNumber, timestamp
  case modelName, systemVersion, deviceName
  case level, category, method, message
  case name, params
}

/// A log on the wire: the payload, with the device and the application it comes from so that
/// Releasy can tell the logs of several applications apart.
struct LogMessage: Encodable {
  let payload: ReleasySender.ReleasyPayload
  let device: ReleasyDevice

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .v)
    try container.encode(payload.id, forKey: .id)
    try container.encode(device.deviceId, forKey: .deviceId)
    try container.encode(device.bundleId, forKey: .bundleId)
    try container.encode(device.buildNumber, forKey: .buildNumber)
    try container.encode(payload.timestamp, forKey: .timestamp)
    switch payload.content {
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

/// The message opening each connection, describing the device so that Releasy lists it before its
/// first log and doesn't need the description in every log.
struct HelloMessage: Encodable {
  let device: ReleasyDevice
  /// The name given to the device when pairing it.
  let deviceName: String?
  let timestamp: TimeInterval

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(1, forKey: .v)
    try container.encode("hello", forKey: .kind)
    try container.encode(device.deviceId, forKey: .deviceId)
    try container.encode(device.bundleId, forKey: .bundleId)
    try container.encode(device.buildNumber, forKey: .buildNumber)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encode(device.modelName, forKey: .modelName)
    try container.encode(device.systemVersion, forKey: .systemVersion)
    try container.encodeIfPresent(deviceName, forKey: .deviceName)
  }
}
