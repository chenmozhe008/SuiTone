import Foundation

struct RegionAdjustment: Codable, Equatable, Sendable {
    var mean: [Double]
    var sourceMean: [Double]
    var chromaScale: [Double]
    var lumaX: [Double]
    var lumaY: [Double]
    var referenceLumaMean: Double
    var strength: Double
    var referenceCount: Int
}

struct AdjustmentParameters: Codable, Equatable, Sendable {
    var water: [Double] = [54, -17, -7]
    var waterVar = 0.6
    var dehazeAmt = 1.0
    var autoDehaze: Bool? = true
    var skyHue = -100.0
    var autumn = 0.25
    var blackWhite = 0.5
    var contrast = 1.0
    var exposure = 0.0
    var saturation = 1.0
    var skinProtect = true
    var smooth = 0.0
    var bright = 0.0
    var matchStrength = 1.0
    var enabled: [String: Bool] = [:]
    var regions: [String: RegionAdjustment] = [:]
}

struct ImportedPhoto: Decodable, Identifiable, Sendable {
    var id: String
    var path: String
    var name: String
    var thumbnail: String
    var original: String
    var width: Int
    var height: Int
    var similarTo: String?
}

struct RemovalOperation: Codable, Equatable, Sendable {
    var box: [Double]
    var classes: [String]?
    var keep: [String]?
}

struct EditSnapshot: Equatable {
    var assetID: String
    var parameters: AdjustmentParameters
    var operations: [RemovalOperation]
    var label: String
}

struct PhotoRecord: Identifiable {
    let imported: ImportedPhoto
    var id: String { imported.id }
    var assetID: String
    var parameters = AdjustmentParameters()
    var operations: [RemovalOperation] = []
    var starred = false
    var excluded = false
    var history: [EditSnapshot] = []
    var future: [EditSnapshot] = []
    var snapshots: [EditSnapshot] = []
    var previewPath: String?

    var snapshot: EditSnapshot {
        EditSnapshot(assetID: assetID, parameters: parameters, operations: operations, label: "调整")
    }
}

struct RegionInfo: Decodable, Sendable {
    var area: Double
    var confidence: Double
    var available: Bool
}

struct AnalysisResponse: Decodable, Sendable {
    var regions: [String: RegionInfo]
    var overlays: [String: String]
    var cacheHit: Bool
    var analysisMs: Double
    var inferenceCount: Int
}

struct PreviewResponse: Decodable, Sendable {
    var preview: String
    var renderMs: Double
    var cacheHit: Bool
    var inferenceCount: Int
    var dehazeAmt: Double
}

struct ImportResponse: Decodable, Sendable {
    var photos: [ImportedPhoto]
    var errors: [String]
}

struct MatchResponse: Decodable, Sendable {
    var params: AdjustmentParameters
    var learned: [String]
    var notes: [String]
    var boundary: String
}

struct RemoveResponse: Decodable, Sendable {
    var id: String
    var source: String
    var mask: String
}

struct ExportOptions: Codable, Sendable {
    var infoBar = false
    var place = ""
    var lut = false
    var denoise = false
    var scale = 1
}

struct ExportResponse: Decodable, Sendable {
    var directory: String
    var files: [String]
    var lutNote: String
}

struct ProjectRecipe: Codable {
    var version: Int = 1
    var photos: [ProjectPhoto]
    var options: ExportOptions
}

struct ProjectPhoto: Codable {
    var path: String
    var params: AdjustmentParameters
    var operations: [RemovalOperation]
}

enum RegionNames {
    static let all = ["water", "sky", "land", "person"]
    static func title(_ key: String) -> String {
        ["water": "水", "sky": "天空", "land": "土地", "person": "人物", "skin": "肤色"][key] ?? key
    }
}
