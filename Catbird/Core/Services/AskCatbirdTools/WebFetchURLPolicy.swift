import Darwin
import Foundation

/// Decides which web addresses Ask Catbird may open.
///
/// The reader only performs anonymous GET requests to public hosts on default ports.
/// Hosts that name the device, the local network or private address space are
/// rejected both by name and by every resolved address, and each redirect is
/// checked again before it is followed.
enum WebFetchURLPolicy {
  enum Rejection: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme
    case embeddedCredentials
    case nonDefaultPort
    case blockedHost
    case unresolvableHost

    var errorDescription: String? {
      switch self {
      case .invalidURL:
        String(localized: "The link is not a valid web address.", comment: "Ask Catbird web reader rejection: malformed URL.")
      case .unsupportedScheme:
        String(localized: "Only http and https links can be read.", comment: "Ask Catbird web reader rejection: unsupported URL scheme.")
      case .embeddedCredentials:
        String(localized: "Links that contain a user name or password cannot be read.", comment: "Ask Catbird web reader rejection: URL contains credentials.")
      case .nonDefaultPort:
        String(localized: "Links that use a custom port cannot be read.", comment: "Ask Catbird web reader rejection: URL uses a non-default port.")
      case .blockedHost:
        String(localized: "Links to this device or a private network cannot be read.", comment: "Ask Catbird web reader rejection: private or local host.")
      case .unresolvableHost:
        String(localized: "The website's address could not be found.", comment: "Ask Catbird web reader rejection: DNS lookup failed.")
      }
    }
  }

  static let maximumURLLength = 2048

  /// Validates the syntax and host name of a link without network access.
  static func validate(_ string: String) throws -> URL {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumURLLength,
          let url = URL(string: trimmed) else { throw Rejection.invalidURL }
    return try validate(url)
  }

  static func validate(_ url: URL) throws -> URL {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased() else { throw Rejection.invalidURL }
    guard scheme == "http" || scheme == "https" else { throw Rejection.unsupportedScheme }
    guard components.user == nil, components.password == nil else { throw Rejection.embeddedCredentials }
    if let port = components.port, port != (scheme == "https" ? 443 : 80) {
      throw Rejection.nonDefaultPort
    }
    guard let rawHost = components.host, !rawHost.isEmpty else { throw Rejection.invalidURL }
    guard !isBlockedHostName(rawHost) else { throw Rejection.blockedHost }
    return url
  }

  /// Rejects names that address the device or a local network, and literal
  /// addresses in private, loopback, link-local, multicast or reserved space.
  static func isBlockedHostName(_ rawHost: String) -> Bool {
    var host = rawHost.lowercased()
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    while host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty else { return true }

    if let address = IPv6Address(host) { return isBlocked(ipv6: address) }
    if let address = IPv4Address(host) { return isBlocked(ipv4: address) }
    if host.contains(":") || host.contains("%") { return true }

    // Single-label names resolve through local search domains, and an all-numeric
    // label is a decimal IPv4 address in disguise.
    guard host.contains(".") else { return true }
    let localSuffixes = [".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".home.arpa", ".localdomain"]
    if host == "localhost" || localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
    return false
  }

  /// Resolves the host and rejects it when any returned address is not public.
  static func validateResolvedAddresses(of url: URL) async throws {
    guard let host = url.host(percentEncoded: false) else { throw Rejection.invalidURL }
    let addresses = try await resolve(host)
    guard !addresses.isEmpty else { throw Rejection.unresolvableHost }
    for address in addresses {
      switch address {
      case .v4(let value): if isBlocked(ipv4: value) { throw Rejection.blockedHost }
      case .v6(let value): if isBlocked(ipv6: value) { throw Rejection.blockedHost }
      }
    }
  }

  // MARK: - Address classification

  struct IPv4Address: Equatable {
    let bytes: [UInt8]

    /// Accepts every form `inet_aton` accepts (including shorthand, octal and hex)
    /// because the system resolver interprets those forms as addresses too.
    init?(_ string: String) {
      guard !string.isEmpty,
            string.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }) else { return nil }
      var address = in_addr()
      guard inet_aton(string, &address) != 0 else { return nil }
      let value = UInt32(bigEndian: address.s_addr)
      bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    init(bytes: [UInt8]) { self.bytes = bytes }
  }

  struct IPv6Address: Equatable {
    let bytes: [UInt8]

    init?(_ string: String) {
      guard string.contains(":") else { return nil }
      var address = in6_addr()
      guard inet_pton(AF_INET6, string, &address) == 1 else { return nil }
      bytes = withUnsafeBytes(of: address) { Array($0) }
    }

    init(bytes: [UInt8]) { self.bytes = bytes }
  }

  enum ResolvedAddress {
    case v4(IPv4Address)
    case v6(IPv6Address)
  }

  static func isBlocked(ipv4 address: IPv4Address) -> Bool {
    let b = address.bytes
    guard b.count == 4 else { return true }
    switch b[0] {
    case 0, 10, 127: return true
    case 100 where (64...127).contains(b[1]): return true
    case 169 where b[1] == 254: return true
    case 172 where (16...31).contains(b[1]): return true
    case 192 where b[1] == 168: return true
    case 192 where b[1] == 0 && (b[2] == 0 || b[2] == 2): return true
    case 198 where b[1] == 18 || b[1] == 19: return true
    case 198 where b[1] == 51 && b[2] == 100: return true
    case 203 where b[1] == 0 && b[2] == 113: return true
    case 224...255: return true
    default: return false
    }
  }

  static func isBlocked(ipv6 address: IPv6Address) -> Bool {
    let b = address.bytes
    guard b.count == 16 else { return true }
    // Unspecified and loopback.
    if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return true }
    // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d) and NAT64 (64:ff9b::/96).
    if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
      return isBlocked(ipv4: IPv4Address(bytes: Array(b[12..<16])))
    }
    if b[0..<12].allSatisfy({ $0 == 0 }) { return true }
    if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B && b[4..<12].allSatisfy({ $0 == 0 }) {
      return isBlocked(ipv4: IPv4Address(bytes: Array(b[12..<16])))
    }
    // 6to4 embeds an IPv4 address in bytes 2–5.
    if b[0] == 0x20 && b[1] == 0x02 {
      return isBlocked(ipv4: IPv4Address(bytes: Array(b[2..<6])))
    }
    if b[0] & 0xFE == 0xFC { return true }                 // Unique local fc00::/7
    if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true } // Link-local fe80::/10
    if b[0] == 0xFE && b[1] & 0xC0 == 0xC0 { return true } // Site-local fec0::/10
    if b[0] == 0xFF { return true }                        // Multicast
    if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return true } // Documentation
    return false
  }

  // MARK: - Resolution

  private static func resolve(_ host: String) async throws -> [ResolvedAddress] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
          continuation.resume(throwing: Rejection.unresolvableHost)
          return
        }
        defer { freeaddrinfo(first) }
        var addresses: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
          if let sockaddr = entry.pointee.ai_addr {
            switch Int32(sockaddr.pointee.sa_family) {
            case AF_INET:
              let value = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
              }
              addresses.append(.v4(IPv4Address(bytes: [
                UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
              ])))
            case AF_INET6:
              let bytes = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
              }
              addresses.append(.v6(IPv6Address(bytes: bytes)))
            default:
              break
            }
          }
          cursor = entry.pointee.ai_next
        }
        continuation.resume(returning: addresses)
      }
    }
  }
}
