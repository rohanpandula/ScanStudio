import Foundation

public struct ControlRollVerifyParams: Codable, Equatable, Sendable {
    public var pass: String?
    public var exposureIdentical: Bool
    public var noClipping: Bool

    public init(pass: String? = nil, exposureIdentical: Bool = false, noClipping: Bool = false) {
        self.pass = pass
        self.exposureIdentical = exposureIdentical
        self.noClipping = noClipping
    }

    private enum CodingKeys: String, CodingKey {
        case pass, exposureIdentical, noClipping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pass = try container.decodeIfPresent(String.self, forKey: .pass)
        exposureIdentical = try container.decodeIfPresent(Bool.self, forKey: .exposureIdentical) ?? false
        noClipping = try container.decodeIfPresent(Bool.self, forKey: .noClipping) ?? false
    }
}

public struct CalibrationVerificationIssue: Codable, Equatable, Sendable {
    public var status: String
    public var jobId: String?
    public var frameIndex: Int?
    public var field: String
    public var detail: String
}

public struct CalibrationVerificationReport: Codable, Equatable, Sendable {
    public var status: String
    public var exposureIdentical: Bool
    public var noClipping: Bool
    public var checkedReceipts: Int
    public var issues: [CalibrationVerificationIssue]
}

public struct CalibrationCollectionMetadata: Codable, Equatable, Sendable {
    public var stock: String
    public var pass: String
    public var slotMap: [String: Int]
    public var firmware: String?
    public var adapter: String?
    public var host: String?
    public var operatorName: String?
    public var appVersion: String?
    public var driverVersion: String?

    enum CodingKeys: String, CodingKey {
        case stock, pass, slotMap, firmware, adapter, host, appVersion, driverVersion
        case operatorName = "operator"
    }

    public init(
        stock: String,
        pass: String,
        slotMap: [String: Int],
        firmware: String? = nil,
        adapter: String? = nil,
        host: String? = nil,
        operatorName: String? = nil,
        appVersion: String? = nil,
        driverVersion: String? = nil
    ) {
        self.stock = stock
        self.pass = pass
        self.slotMap = slotMap
        self.firmware = firmware
        self.adapter = adapter
        self.host = host
        self.operatorName = operatorName
        self.appVersion = appVersion
        self.driverVersion = driverVersion
    }
}

public struct ControlRollCollectParams: Codable, Equatable, Sendable {
    public var to: String
    public var metadata: CalibrationCollectionMetadata

    public init(to: String, metadata: CalibrationCollectionMetadata) {
        self.to = to
        self.metadata = metadata
    }
}

public struct CalibrationCollectedFile: Codable, Equatable, Sendable {
    public var path: String
    public var byteLength: UInt64
    public var sha256: String
}

public struct CalibrationCollectionResult: Codable, Equatable, Sendable {
    public var destination: String
    public var files: [CalibrationCollectedFile]
    public var metadataPath: String
    public var hashesPath: String
}
