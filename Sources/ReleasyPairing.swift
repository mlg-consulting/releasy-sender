import CryptoKit
import Foundation
import Network

/// What the application needs to send its logs to a Releasy: the identifier of the Mac, and the
/// secret that encrypts the connection.
///
/// Releasy shows it as a QR code of a link such as `releasy://pair?mac=…&secret=…`. The application
/// registers the `releasy` URL scheme, creates the pairing from the link it opens, and hands it to
/// `ReleasySender.pair(with:)`.
public struct ReleasyPairing: Codable, Equatable, Sendable {
  /// The identifier the paired Releasy advertises in the TXT record of its Bonjour service.
  public let macId: String
  let secret: String

  /// Reads a pairing link, whatever its scheme. `nil` when it doesn't hold both the Mac identifier
  /// and the secret.
  public init?(url: URL) {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard
      url.host == "pair",
      let macId = items.first(where: { $0.name == "mac" })?.value, !macId.isEmpty,
      let secret = items.first(where: { $0.name == "secret" })?.value, !secret.isEmpty
    else {
      return nil
    }
    self.macId = macId
    self.secret = secret
  }
}

extension ReleasyPairing {
  /// TLS 1.2 with a pre-shared key, the SHA-256 of the secret, and the identity `macId`, as Releasy
  /// expects.
  var tlsOptions: NWProtocolTLS.Options {
    let tls = NWProtocolTLS.Options()
    let key = Data(SHA256.hash(data: Data(secret.utf8))).withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data(macId.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(
      tls.securityProtocolOptions,
      key as __DispatchData,
      identity as __DispatchData
    )
    sec_protocol_options_append_tls_ciphersuite(
      tls.securityProtocolOptions,
      tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
    )
    // TLS 1.3 handles pre-shared keys differently: both sides stay on TLS 1.2.
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    // Releasy refuses to resume a session, so that a replaced secret can no longer connect.
    sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
    sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
    return tls
  }
}
