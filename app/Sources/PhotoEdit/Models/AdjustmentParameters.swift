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

/// 某个区域（天空、水面、地面、人物）的局部光线和颜色；数值含义与引擎 grade.LOCAL_FIELDS 一致。
struct LocalAdjustment: Codable, Equatable, Sendable {
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var temperature = 0.0
    var saturation = 0.0
    var hue = 0.0
    var feather = 0.5

    init() {}
    enum CodingKeys: String, CodingKey { case exposure, contrast, highlights, temperature, saturation, hue, feather }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
    }
    var isNeutral: Bool { [exposure, contrast, highlights, temperature, saturation, hue].allSatisfy { $0 == 0 } }
}

struct AdjustmentParameters: Codable, Equatable, Sendable {
    var water: [Double] = [54, -17, -7]
    var waterVar = 0.6
    var dehazeAmt = 0.0
    var autoDehaze: Bool? = false
    var skyHue = -100.0
    var autumn = 0.25
    var blackWhite = 0.0
    var contrast = 0.0
    var exposure = 0.0
    var saturation = 1.0
    var temperature = 0.0
    var tint = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var effectStrength = 1.0
    var shadowHue = -160.0
    var shadowChroma = 0.0
    var highlightHue = 65.0
    var highlightChroma = 0.0
    var fade = 0.0
    var skinProtect = true
    var smooth = 0.0
    var bright = 0.0
    var matchStrength = 1.0
    var whites = 0.0
    var blacks = 0.0
    var light = 0.0
    var vibrance = 0.0
    var texture = 0.0
    var enabled: [String: Bool] = ["water":false,"sky":false,"land":false]
    var regions: [String: RegionAdjustment] = [:]
    var local: [String: LocalAdjustment] = [:]
    var manualMasks: [String: RemovalOperation] = [:]
    var hasReferenceMatch: Bool { regions.values.contains { $0.referenceCount > 0 } }

    init() {}
    enum CodingKeys:String,CodingKey {
        case water,waterVar,dehazeAmt,autoDehaze,skyHue,autumn,blackWhite,contrast,exposure,saturation
        case temperature,tint,highlights,shadows,effectStrength,skinProtect,smooth,bright,matchStrength,enabled,regions
        case shadowHue,shadowChroma,highlightHue,highlightChroma,fade
        case whites,blacks,light,vibrance,texture,local,manualMasks
    }
    init(from decoder:Decoder) throws {
        self.init()
        let c=try decoder.container(keyedBy:CodingKeys.self)
        water=try c.decodeIfPresent([Double].self,forKey:.water) ?? water
        enabled=try c.decodeIfPresent([String:Bool].self,forKey:.enabled) ?? enabled
        regions=try c.decodeIfPresent([String:RegionAdjustment].self,forKey:.regions) ?? regions
        skinProtect=try c.decodeIfPresent(Bool.self,forKey:.skinProtect) ?? true
        autoDehaze=try c.decodeIfPresent(Bool.self,forKey:.autoDehaze) ?? false
        waterVar=try c.decodeIfPresent(Double.self,forKey:.waterVar) ?? waterVar
        dehazeAmt=try c.decodeIfPresent(Double.self,forKey:.dehazeAmt) ?? dehazeAmt
        skyHue=try c.decodeIfPresent(Double.self,forKey:.skyHue) ?? skyHue
        autumn=try c.decodeIfPresent(Double.self,forKey:.autumn) ?? autumn
        blackWhite=try c.decodeIfPresent(Double.self,forKey:.blackWhite) ?? blackWhite
        contrast=try c.decodeIfPresent(Double.self,forKey:.contrast) ?? contrast
        exposure=try c.decodeIfPresent(Double.self,forKey:.exposure) ?? exposure
        saturation=try c.decodeIfPresent(Double.self,forKey:.saturation) ?? saturation
        temperature=try c.decodeIfPresent(Double.self,forKey:.temperature) ?? temperature
        tint=try c.decodeIfPresent(Double.self,forKey:.tint) ?? tint
        highlights=try c.decodeIfPresent(Double.self,forKey:.highlights) ?? highlights
        shadows=try c.decodeIfPresent(Double.self,forKey:.shadows) ?? shadows
        effectStrength=try c.decodeIfPresent(Double.self,forKey:.effectStrength) ?? effectStrength
        shadowHue=try c.decodeIfPresent(Double.self,forKey:.shadowHue) ?? shadowHue
        shadowChroma=try c.decodeIfPresent(Double.self,forKey:.shadowChroma) ?? shadowChroma
        highlightHue=try c.decodeIfPresent(Double.self,forKey:.highlightHue) ?? highlightHue
        highlightChroma=try c.decodeIfPresent(Double.self,forKey:.highlightChroma) ?? highlightChroma
        fade=try c.decodeIfPresent(Double.self,forKey:.fade) ?? fade
        smooth=try c.decodeIfPresent(Double.self,forKey:.smooth) ?? smooth
        bright=try c.decodeIfPresent(Double.self,forKey:.bright) ?? bright
        matchStrength=try c.decodeIfPresent(Double.self,forKey:.matchStrength) ?? matchStrength
        whites=try c.decodeIfPresent(Double.self,forKey:.whites) ?? 0
        blacks=try c.decodeIfPresent(Double.self,forKey:.blacks) ?? 0
        light=try c.decodeIfPresent(Double.self,forKey:.light) ?? 0
        vibrance=try c.decodeIfPresent(Double.self,forKey:.vibrance) ?? 0
        texture=try c.decodeIfPresent(Double.self,forKey:.texture) ?? 0
        local=try c.decodeIfPresent([String:LocalAdjustment].self,forKey:.local) ?? [:]
        manualMasks=try c.decodeIfPresent([String:RemovalOperation].self,forKey:.manualMasks) ?? [:]
    }
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
    /// 画笔轨迹（比例坐标折线）与笔刷半径（占画面宽度比例）
    var strokes: [[[Double]]]? = nil
    var radius: Double? = nil
    /// 套索多边形
    var polygon: [[Double]]? = nil
    /// 点选物体的位置
    var point: [Double]? = nil
}

struct EditSnapshot: Equatable {
    var assetID: String
    var parameters: AdjustmentParameters
    var operations: [RemovalOperation]
    var label: String
    var lookName: String
    var notes: [String]
    var quality = QualitySettings()
}

struct QualitySettings: Codable, Equatable, Sendable {
    var denoise = false
    var scale = 1
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
    var lookName = "原图"
    var notes: [String] = []
    var ready = false
    var quality = QualitySettings()

    var snapshot: EditSnapshot {
        EditSnapshot(assetID: assetID, parameters: parameters, operations: operations, label: "调整",lookName:lookName,notes:notes,quality:quality)
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
    var format: String? = "jpeg"
    var infoBar = false
    var place = ""
    var lut = false
    var denoise = false
    var scale = 1

    enum CodingKeys: String, CodingKey { case format, infoBar, place, lut, denoise, scale }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encode(infoBar, forKey: .infoBar)
        try c.encode(place, forKey: .place)
        try c.encode(lut, forKey: .lut)
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        infoBar = try c.decodeIfPresent(Bool.self, forKey: .infoBar) ?? false
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        lut = try c.decodeIfPresent(Bool.self, forKey: .lut) ?? false
        // 只读取旧调整记录；新记录把画质保存在每张照片上。
        denoise = try c.decodeIfPresent(Bool.self, forKey: .denoise) ?? false
        scale = try c.decodeIfPresent(Int.self, forKey: .scale) ?? 1
    }
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
    var quality: QualitySettings? = nil

    func restoredQuality(options: ExportOptions) -> QualitySettings {
        quality ?? QualitySettings(denoise: options.denoise, scale: options.scale)
    }
}

enum RegionNames {
    static let all = ["water", "sky", "land", "person"]
    static func title(_ key: String) -> String {
        if key.hasPrefix("selection-") { return "选区" }
        return ["water": "水面", "sky": "天空", "land": "地面", "person": "人物", "skin": "肤色"][key] ?? key
    }
}
