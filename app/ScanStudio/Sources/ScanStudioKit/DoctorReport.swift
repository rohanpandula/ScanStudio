import Foundation

public enum DoctorCheckStatus: String, Codable, Equatable, Sendable {
    case pass, warn, fail
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let id: String
    public let status: DoctorCheckStatus
    public let value: String?
    public let detail: String
    public let fix: String?
}

/// One independently observed fact. Missing evidence is a warning; evidence
/// proving an invalid installation or unsafe local authority is a failure.
public enum DoctorObservation: Equatable, Sendable {
    case available(id: String, value: String, detail: String)
    case warning(id: String, value: String?, detail: String, fix: String)
    case invalid(id: String, value: String?, detail: String, fix: String)
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let checks: [DoctorCheck]
    public let passCount: Int
    public let warnCount: Int
    public let failCount: Int

    public init(generatedAt: String, observations: [DoctorObservation]) {
        self.generatedAt = generatedAt
        checks = observations.map { observation in
            switch observation {
            case let .available(id, value, detail):
                DoctorCheck(id: id, status: .pass, value: value, detail: detail, fix: nil)
            case let .warning(id, value, detail, fix):
                DoctorCheck(id: id, status: .warn, value: value, detail: detail, fix: fix)
            case let .invalid(id, value, detail, fix):
                DoctorCheck(id: id, status: .fail, value: value, detail: detail, fix: fix)
            }
        }
        passCount = checks.count { $0.status == .pass }
        warnCount = checks.count { $0.status == .warn }
        failCount = checks.count { $0.status == .fail }
    }

    public var hasFailures: Bool { failCount > 0 }
}
