import Foundation
import Testing

@testable import ScanStudioKit

@Suite("Browser preview network preferences")
struct WebServerPreferencesTests {
    @Test("safe defaults bind only this Mac with token authentication")
    func safeDefaults() throws {
        let configuration = try WebServerNetworkResolver.resolve(
            WebServerPreferences(),
            privateLANAddresses: ["192.168.50.4"]
        )

        #expect(configuration.bindAddress == "127.0.0.1")
        #expect(configuration.port == 8787)
        #expect(configuration.authenticationMode == .accessToken)
        #expect(configuration.allowedOrigins == ["http://127.0.0.1:8787"])
        #expect(!configuration.cookieSecure)
        #expect(configuration.readinessURL.absoluteString == "http://127.0.0.1:8787/")
        #expect(configuration.browserURL.absoluteString == "http://127.0.0.1:8787/")
    }

    @Test("local-network binding advertises only explicit private addresses")
    func localNetworkAddresses() throws {
        let preferences = WebServerPreferences(
            bindScope: .localNetwork,
            port: 9000,
            authenticationMode: .accessToken
        )

        let configuration = try WebServerNetworkResolver.resolve(
            preferences,
            privateLANAddresses: [
                "192.168.1.20",
                "8.8.8.8",
                "fd12:3456::9",
                "169.254.2.3",
                "192.168.1.20",
            ]
        )

        #expect(configuration.bindAddress == "0.0.0.0")
        #expect(configuration.allowedOrigins == ["http://192.168.1.20:9000"])
        #expect(configuration.advertisedURLs.map(\.absoluteString) == [
            "http://192.168.1.20:9000/",
        ])
    }

    @Test("trusted LAN cannot be selected on loopback or a public address")
    func trustedLANRequiresPrivateInterface() {
        #expect(throws: WebServerPreferencesError.trustedLANRequiresPrivateInterface) {
            try WebServerNetworkResolver.resolve(
                WebServerPreferences(authenticationMode: .trustedLAN),
                privateLANAddresses: ["192.168.1.20"]
            )
        }
        #expect(throws: WebServerPreferencesError.trustedLANRequiresPrivateInterface) {
            try WebServerNetworkResolver.resolve(
                WebServerPreferences(
                    bindScope: .custom,
                    customBindAddress: "203.0.113.10",
                    authenticationMode: .trustedLAN
                )
            )
        }
    }

    @Test("trusted LAN accepts RFC1918 and ULA addresses only")
    func trustedLANAddressFamilies() throws {
        for address in ["10.1.2.3", "172.16.9.4", "172.31.255.254", "192.168.4.8", "fd00::1"] {
            let configuration = try WebServerNetworkResolver.resolve(
                WebServerPreferences(
                    bindScope: .custom,
                    customBindAddress: address,
                    authenticationMode: .trustedLAN
                )
            )
            #expect(configuration.bindAddress == address)
            #expect(configuration.authenticationMode == .trustedLAN)
            if address.contains(":") {
                #expect(configuration.allowedOrigins == ["http://[fd00::1]:8787"])
            }
        }
        for address in ["127.0.0.1", "172.32.0.1", "169.254.1.1", "100.64.0.1", "fe80::1", "2001:4860:4860::8888"] {
            #expect(!WebServerNetworkResolver.isPrivateLANAddress(address))
        }
    }

    @Test("trusted LAN rejects custom origins while token mode validates them")
    func originsAreModeSpecific() throws {
        #expect(throws: WebServerPreferencesError.trustedLANDoesNotSupportAdditionalOrigins) {
            try WebServerNetworkResolver.resolve(
                WebServerPreferences(
                    bindScope: .localNetwork,
                    authenticationMode: .trustedLAN,
                    additionalOrigins: "https://scan.example.test"
                ),
                privateLANAddresses: ["192.168.1.20"]
            )
        }

        let configuration = try WebServerNetworkResolver.resolve(
            WebServerPreferences(
                additionalOrigins: "https://scan.example.test, https://scan.example.test:8443/"
            )
        )
        #expect(configuration.allowedOrigins == [
            "https://scan.example.test",
            "https://scan.example.test:8443",
        ])
        #expect(configuration.cookieSecure)
        #expect(configuration.readinessURL.absoluteString == "http://127.0.0.1:8787/")
        #expect(configuration.browserURL.absoluteString == "https://scan.example.test/")
        #expect(configuration.advertisedURLs.map(\.absoluteString) == [
            "https://scan.example.test/",
            "https://scan.example.test:8443/",
        ])

        let ipv6 = try WebServerNetworkResolver.resolve(
            WebServerPreferences(additionalOrigins: "https://[fd00::1]:8443")
        )
        #expect(ipv6.allowedOrigins == ["https://[fd00::1]:8443"])

        for origin in [
            "ftp://scan.example.test",
            "https://user:pass@scan.example.test",
            "https://scan.example.test/path",
            "https://scan.example.test/?token=secret",
            "https://scan.example.test:65536",
            "https://scan.example.test:99999999999999999999999",
            "https://[fd00::1%25en0]",
            "https://[%25]",
            "https://foo%2Cbar",
            "https://foo,bar",
            "https://[foo:bar]",
        ] {
            #expect(throws: WebServerPreferencesError.self) {
                try WebServerNetworkResolver.resolve(
                    WebServerPreferences(additionalOrigins: origin)
                )
            }
        }
    }

    @Test("port and interface validation fail closed")
    func invalidSettings() {
        for port in [0, 1023, 65_536] {
            #expect(throws: WebServerPreferencesError.invalidPort) {
                try WebServerNetworkResolver.resolve(WebServerPreferences(port: port))
            }
        }
        #expect(throws: WebServerPreferencesError.noPrivateLANInterface) {
            try WebServerNetworkResolver.resolve(
                WebServerPreferences(bindScope: .localNetwork),
                privateLANAddresses: []
            )
        }
        #expect(throws: WebServerPreferencesError.invalidBindAddress) {
            try WebServerNetworkResolver.resolve(
                WebServerPreferences(bindScope: .custom, customBindAddress: "scanner.local")
            )
        }
        for address in ["0.0.0.0", "255.255.255.255", "224.0.0.1", "::", "ff02::1"] {
            #expect(throws: WebServerPreferencesError.invalidBindAddress) {
                try WebServerNetworkResolver.resolve(
                    WebServerPreferences(bindScope: .custom, customBindAddress: address)
                )
            }
        }
    }
}
