import Foundation

/// 用户存下的风格：一整套参数，可套用到所选照片。
struct MyStyle: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var parameters: AdjustmentParameters
}

struct WorkspaceChange {
    let id = UUID()
    var label:String
    var before:[String:EditSnapshot]
    var after:[String:EditSnapshot]
}

struct RepairDraft {
    let photoID: String
    let sourceAssetID: String
    let parameters: AdjustmentParameters
    let operation: RemovalOperation
    let resultAssetID: String
    let beforePath: String
    let previewPath: String
}

struct SmartResponse:Decodable {
    var params:AdjustmentParameters
    var title:String
    var notes:[String]
    var preview:String
}

/// 风格列表由引擎 `/styles` 提供（engine/smart.py 的 STYLES），App 不另存一份。
struct StylePreset: Decodable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let family: String
    var creative: Bool { family == "creative" }
}

struct AssistantProvider:Decodable,Identifiable {
    var id:String
    var title:String
    var available:Bool
    /// account = 本机已登录的 CLI；api = 用户自填密钥
    var kind:String = "account"
    var models:[String] = []
    var needsBaseUrl:Bool = false
    var isAPI:Bool { kind == "api" }

    enum CodingKeys: String, CodingKey { case id, title, available, kind, models, needsBaseUrl }
    init(id:String,title:String,available:Bool,kind:String="account",models:[String]=[],needsBaseUrl:Bool=false) {
        self.id=id;self.title=title;self.available=available;self.kind=kind;self.models=models;self.needsBaseUrl=needsBaseUrl
    }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);title=try c.decode(String.self,forKey:.title)
        available=try c.decode(Bool.self,forKey:.available)
        kind=try c.decodeIfPresent(String.self,forKey:.kind) ?? "account"
        models=try c.decodeIfPresent([String].self,forKey:.models) ?? []
        needsBaseUrl=try c.decodeIfPresent(Bool.self,forKey:.needsBaseUrl) ?? false
    }
}

/// 发给引擎的 API 接入参数；密钥只在内存和钥匙串里。
struct APICredentials: Sendable {
    var key: String
    var model: String
    var baseURL: String
    func apply(to body: inout [String: Any]) {
        body["api_key"] = key
        if !model.isEmpty { body["model"] = model }
        if !baseURL.isEmpty { body["base_url"] = baseURL }
    }
}

struct SuggestionCard: Decodable, Identifiable {
    var id: String
    var title: String
}

struct SuggestionsResponse: Decodable {
    var cards: [SuggestionCard]
    var source: String
    var cacheHit: Bool
}

struct ChatMessage:Identifiable {
    let id=UUID()
    var role:String
    var text:String
    var notes:[String]=[]
    var affectedPhotos:[String]=[]
    var changeID: UUID? = nil
    var wasUndone = false
    var variants: [VariantPreview] = []
}

struct VariantPreview: Identifiable {
    let id = UUID()
    let group: UUID
    let photoID: String
    let baseline: EditSnapshot
    let title: String
    let params: AdjustmentParameters
    let notes: [String]
    let preview: String
}

struct AssistantVariant: Decodable {
    var id: String
    var title: String
    var params: AdjustmentParameters
    var notes: [String]
}

struct AssistantChange:Decodable {
    var id:String
    var params:AdjustmentParameters
    var notes:[String]
    var operations: [AssistantOperation]? = nil
}

struct AssistantOperation: Decodable {
    var kind: String
    var value: Double
}

struct AssistantJob:Decodable {
    var state:String
    var reply:String?
    var selection:String?
    var changes:[AssistantChange]?
    var error:String?
    var variants: [AssistantVariant]? = nil
}
