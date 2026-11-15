import Foundation

// MARK: - 零件定义（对应 parts_seed.json）

public struct PortDef: Codable, Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    /// 度数，端口朝向 = 轨道从件内指向外的切线方向
    public let heading: Double
    /// M = 凸榫(公头), F = 凹槽(母口)
    public let polarity: String
    /// 相对基准地面高度
    public let level: Double

    public var position: Vec2 { Vec2(x: x, y: y) }
    public var headingRadians: Double { heading * .pi / 180 }
}

public struct PartDef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let alias: String?
    public let family: String
    public let confidence: String
    public let geometry: [String: Double]
    public let ports: [PortDef]
    public let notes: String?

    public func port(_ id: String) -> PortDef? { ports.first { $0.id == id } }
    public var length: Double? { geometry["length"] }
    public var radius: Double? { geometry["radius"] }
    public var branchRadius: Double? { geometry["branch_radius"] }
}

struct RawLibrary: Codable {
    let parts: [PartDef]
}

public enum LibraryError: Error {
    case missingResource
}

public struct PartLibrary: Sendable {
    public let parts: [PartDef]
    public let byId: [String: PartDef]

    public init(parts: [PartDef]) {
        self.parts = parts
        var index: [String: PartDef] = [:]
        for p in parts { index[p.id] = p }
        self.byId = index
    }

    /// 加载种子零件库。
    /// 作为 Swift Package 编译时从包资源读取；直接编译进 App 目标时从主 Bundle 读取。
    public static func load() throws -> PartLibrary {
        #if SWIFT_PACKAGE
        let bundle: Bundle = Bundle.module
        #else
        let bundle: Bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "parts_seed", withExtension: "json") else {
            throw LibraryError.missingResource
        }
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode(RawLibrary.self, from: data)
        return PartLibrary(parts: raw.parts)
    }
}
