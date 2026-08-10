import Darwin
import Foundation

public enum WebServerBindScope: String, CaseIterable, Sendable {
    case thisMac = "this-mac"
    case localNetwork = "local-network"
    case custom = "custom"
}

public enum WebServerAuthenticationMode: String, CaseIterable, Sendable {
    case accessToken = "token"
    case trustedLAN = "trusted-lan-no-login"
}

public struct WebServerPreferences: Equatable, Sendable {
    public var bindScope: WebServerBindScope
    public var customBindAddress: String
    public var port: Int
    public var authenticationMode: WebServerAuthenticationMode
    public var additionalOrigins: String

    public init(
        bindScope: WebServerBindScope = .thisMac,
        customBindAddress: String = "",
        port: Int = 8787,
        authenticationMode: WebServerAuthenticationMode = .accessToken,
        additionalOrigins: String = ""
    ) {
        self.bindScope = bindScope
        self.customBindAddress = customBindAddress
        self.port = port
        self.authenticationMode = authenticationMode
        self.additionalOrigins = additionalOrigins
    }
}

public struct WebServerNetworkConfiguration: Equatable, Sendable {
    public let bindAddress: String
    public let port: UInt16
    public let authenticationMode: WebServerAuthenticationMode
    public let allowedOrigins: [String]
    public let cookieSecure: Bool
    public let readinessURL: URL
    public let browserURL: URL
    public let advertisedURLs: [URL]
}

public enum WebServerPreferencesError: Error, LocalizedError, Equatable {
    case invalidPort
    case noPrivateLANInterface
    case invalidBindAddress
    case trustedLANRequiresPrivateInterface
    case trustedLANDoesNotSupportAdditionalOrigins
    case invalidOrigin(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Choose a port from 1024 through 65535."
        case .noPrivateLANInterface:
            return "No private IPv4 local-network address is available. Connect this Mac to a trusted network, choose a specific IPv6 address, or choose This Mac Only."
        case .invalidBindAddress:
            return "Enter a numeric IPv4 or IPv6 listen address."
        case .trustedLANRequiresPrivateInterface:
            return "Trusted LAN without a login requires a private network interface; it cannot run on localhost or a public address."
        case .trustedLANDoesNotSupportAdditionalOrigins:
            return "Custom browser origins are unavailable when login is disabled for a trusted LAN."
        case .invalidOrigin(let value):
            return "The browser origin is invalid: \(value). Use an exact http:// or https:// address without a path."
        }
    }
}

public enum WebServerNetworkResolver {
    public static func resolve(
        _ preferences: WebServerPreferences,
        privateLANAddresses: [String] = SystemLANAddressProvider.privateAddresses()
    ) throws -> WebServerNetworkConfiguration {
        guard (1024 ... 65535).contains(preferences.port),
              let port = UInt16(exactly: preferences.port) else {
            throw WebServerPreferencesError.invalidPort
        }

        let lanAddresses = stableUnique(
            privateLANAddresses.filter { isPrivateLANAddress($0) }
        )
        let bindAddress: String
        let advertisedAddresses: [String]

        switch preferences.bindScope {
        case .thisMac:
            guard preferences.authenticationMode != .trustedLAN else {
                throw WebServerPreferencesError.trustedLANRequiresPrivateInterface
            }
            bindAddress = "127.0.0.1"
            advertisedAddresses = [bindAddress]
        case .localNetwork:
            // Uvicorn's 0.0.0.0 socket is IPv4-only. Do not advertise ULA
            // addresses that this process did not bind; users can select an
            // exact ULA through the custom-address option instead.
            let privateIPv4Addresses = lanAddresses.filter(isIPv4Address)
            guard !privateIPv4Addresses.isEmpty else {
                throw WebServerPreferencesError.noPrivateLANInterface
            }
            bindAddress = "0.0.0.0"
            advertisedAddresses = privateIPv4Addresses
        case .custom:
            let candidate = preferences.customBindAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUsableBindAddress(candidate) else {
                throw WebServerPreferencesError.invalidBindAddress
            }
            if preferences.authenticationMode == .trustedLAN,
               !isPrivateLANAddress(candidate) {
                throw WebServerPreferencesError.trustedLANRequiresPrivateInterface
            }
            bindAddress = candidate
            advertisedAddresses = [candidate]
        }

        if preferences.authenticationMode == .trustedLAN,
           !preferences.additionalOrigins.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WebServerPreferencesError.trustedLANDoesNotSupportAdditionalOrigins
        }

        let advertisedURLs = advertisedAddresses.compactMap {
            makeURL(scheme: "http", address: $0, port: port)
        }
        guard let browserURL = advertisedURLs.first else {
            throw WebServerPreferencesError.invalidBindAddress
        }

        let localOrigins = advertisedURLs.compactMap(originString)
        var additionalOriginValues: [String] = []
        if preferences.authenticationMode == .accessToken {
            for value in splitOrigins(preferences.additionalOrigins) {
                let origin = try validateOrigin(value)
                additionalOriginValues.append(origin)
            }
        }
        let additionalSchemes = Set(additionalOriginValues.compactMap {
            URLComponents(string: $0)?.scheme?.lowercased()
        })
        guard additionalSchemes.count <= 1 else {
            throw WebServerPreferencesError.invalidOrigin(
                "Do not mix HTTP and HTTPS browser origins"
            )
        }
        let cookieSecure = additionalSchemes == Set(["https"])
        let externalURLs = additionalOriginValues.compactMap { value -> URL? in
            guard var components = URLComponents(string: value) else { return nil }
            components.path = "/"
            return components.url
        }
        // A Secure session cookie cannot be used over the gateway's local
        // plain-HTTP address. When an HTTPS proxy origin is configured, show
        // and authorize only the proxy URLs while retaining a private local
        // URL solely for the process readiness probe.
        let origins = cookieSecure
            ? additionalOriginValues
            : localOrigins + additionalOriginValues
        let userFacingURLs = cookieSecure
            ? stableUniqueURLs(externalURLs)
            : stableUniqueURLs(externalURLs + advertisedURLs)

        return WebServerNetworkConfiguration(
            bindAddress: bindAddress,
            port: port,
            authenticationMode: preferences.authenticationMode,
            allowedOrigins: stableUnique(origins),
            cookieSecure: cookieSecure,
            readinessURL: browserURL,
            browserURL: userFacingURLs.first ?? browserURL,
            advertisedURLs: userFacingURLs
        )
    }

    public static func isPrivateLANAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let hostOrder = UInt32(bigEndian: ipv4.s_addr)
            return (hostOrder & 0xFF00_0000) == 0x0A00_0000
                || (hostOrder & 0xFFF0_0000) == 0xAC10_0000
                || (hostOrder & 0xFFFF_0000) == 0xC0A8_0000
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { bytes in
                guard let first = bytes.first else { return false }
                return first & 0xFE == 0xFC
            }
        }
        return false
    }

    public static func isNumericIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, value, &ipv6) == 1
    }

    private static func isUsableBindAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let hostOrder = UInt32(bigEndian: ipv4.s_addr)
            return hostOrder != 0
                && hostOrder != UInt32.max
                && (hostOrder & 0xF000_0000) != 0xE000_0000
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, value, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            bytes.contains(where: { $0 != 0 }) && bytes.first != 0xFF
        }
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, value, &address) == 1
    }

    private static func splitOrigins(_ raw: String) -> [String] {
        raw.split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func validateOrigin(_ raw: String) throws -> String {
        guard let components = URLComponents(string: raw),
              !raw.contains("%"),
              !raw.contains(","),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host,
              !host.isEmpty,
              isValidOriginHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw WebServerPreferencesError.invalidOrigin(raw)
        }
        let parsedPort = try explicitPort(in: raw)
        guard parsedPort == components.port else {
            throw WebServerPreferencesError.invalidOrigin(raw)
        }

        var canonical = URLComponents()
        let scheme = components.scheme?.lowercased()
        canonical.scheme = scheme
        setHost(host, on: &canonical)
        let defaultPort = scheme == "https" ? 443 : 80
        canonical.port = components.port == defaultPort ? nil : components.port
        guard let value = canonical.string else {
            throw WebServerPreferencesError.invalidOrigin(raw)
        }
        return value
    }

    /// Returns the explicit port, or nil when the origin has no port. Invalid
    /// and overflowing values throw because URLComponents otherwise silently
    /// normalizes some of them to `nil`.
    private static func explicitPort(in raw: String) throws -> Int? {
        guard let separator = raw.range(of: "://") else {
            throw WebServerPreferencesError.invalidOrigin(raw)
        }
        let remainder = raw[separator.upperBound...]
        let authority = remainder.prefix { !"/?#".contains($0) }
        let suffix: Substring
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else {
                throw WebServerPreferencesError.invalidOrigin(raw)
            }
            suffix = authority[authority.index(after: closing)...]
        } else {
            let colonCount = authority.filter { $0 == ":" }.count
            guard colonCount <= 1 else {
                throw WebServerPreferencesError.invalidOrigin(raw)
            }
            suffix = authority.firstIndex(of: ":").map { authority[$0...] } ?? ""
        }
        guard !suffix.isEmpty else { return nil }
        guard suffix.first == ":" else {
            throw WebServerPreferencesError.invalidOrigin(raw)
        }
        let digits = suffix.dropFirst()
        guard !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              let port = Int(digits),
              (1 ... 65535).contains(port) else {
            throw WebServerPreferencesError.invalidOrigin(raw)
        }
        return port
    }

    private static func isValidOriginHost(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.hasSuffix("]") || host.contains(":") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { return false }
            let address = String(host.dropFirst().dropLast())
            var ipv6 = in6_addr()
            return !address.isEmpty && inet_pton(AF_INET6, address, &ipv6) == 1
        }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return true }
        guard host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy(\.isASCII),
              !host.hasPrefix("."),
              !host.hasSuffix(".") else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            guard !$0.isEmpty, $0.utf8.count <= 63,
                  let first = $0.first, let last = $0.last,
                  first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber else {
                return false
            }
            return $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func makeURL(scheme: String, address: String, port: UInt16) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        setHost(address, on: &components)
        components.port = Int(port)
        components.path = "/"
        return components.url
    }

    private static func originString(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            return nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        setHost(host, on: &origin)
        origin.port = components.port
        return origin.string
    }

    private static func setHost(_ host: String, on components: inout URLComponents) {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            components.percentEncodedHost = host
        } else if host.contains(":") {
            components.percentEncodedHost = "[\(host)]"
        } else {
            components.host = host
        }
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func stableUniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.absoluteString).inserted }
    }
}

public enum SystemLANAddressProvider {
    public static func privateAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var values: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                address,
                length,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let value = String(decoding: bytes, as: UTF8.self)
                .split(separator: "%", maxSplits: 1)
                .first.map(String.init) ?? ""
            if WebServerNetworkResolver.isPrivateLANAddress(value),
               !values.contains(value) {
                values.append(value)
            }
        }
        return values
    }
}
