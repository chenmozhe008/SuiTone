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
    /// 对应图集里那一条历史记录（撤销时一起抹掉）
    var stepID:String? = nil
    /// 「回到历史某一步」的跳转操作：存目标步骤 id。跳转不新增历史条目，
    /// 重做跳转时也只在历史里高亮目标步骤，不追加重复记录。
    var jumpStepID:String? = nil
    /// 跳转前所在的历史步骤（撤销跳转时回到这里）；普通改动不用。
    var fromStepID:String? = nil
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

/// 引擎按照片内容给出的首屏顺序（engine/style_guide.py）；只是排序和一句理由。
struct StyleGuide: Decodable {
    let scene: String
    let sceneTitle: String
    let reason: String
    let natural: [String]
    let creative: [String]
    func ids(_ family: String) -> [String] { family == "creative" ? creative : natural }
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
    /// AI 认为必须生成新图时的确认卡；用户点「生成」才发送
    var generation: GenerationCard? = nil
}

/// 生成新图的确认卡状态：proposed 待确认 / running 生成中 / done 已采用 / failed 失败 / cancelled 已取消 / dismissed 不用了
struct GenerationCard {
    var photoID: String
    var prompt: String
    var state = "proposed"
    var error: String? = nil
    var preview: String? = nil
    /// 对照图片只在当前会话保留，不改变已采用的版本。
    var beforePreview: String? = nil
    var modelPreview: String? = nil
    var jobID: String? = nil
    /// 只改选区时的选区（原尺寸上只替换这一块）；nil 为整张
    var selection: RemovalOperation? = nil
    var selectionGuidance = "coordinates"
    /// 附加参考图的本地路径（姿势、风格、物品等；张数按所选模型的官方上限）
    var references: [String] = []
    var aspectRatio: String? = nil
}

struct GenerationProposal: Decodable { var prompt: String }

/// 出图服务（引擎 `/image-services` 提供）；mock 只在测试启动参数下出现
struct ImageService: Decodable, Identifiable {
    let id: String
    let title: String
    let defaultModel: String
    let paid: Bool
    /// 推荐模型，第一个最新（引擎按官方文档维护）
    var models: [String] = []
    /// 每个型号能加几张参考图（原图另计）；数字由引擎按服务商官方文档给出，界面不自己定
    var referenceLimits: [String: Int] = [:]
    enum CodingKeys: String, CodingKey { case id, title, defaultModel, paid, models, referenceLimits }
    init(id: String, title: String, defaultModel: String, paid: Bool, models: [String] = [], referenceLimits: [String: Int] = [:]) {
        self.id = id; self.title = title; self.defaultModel = defaultModel; self.paid = paid
        self.models = models; self.referenceLimits = referenceLimits
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        defaultModel = try c.decode(String.self, forKey: .defaultModel); paid = try c.decode(Bool.self, forKey: .paid)
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        referenceLimits = try c.decodeIfPresent([String: Int].self, forKey: .referenceLimits) ?? [:]
    }
}

/// 模型名按新旧排：比较名字里的数字（版本号、日期），大的在前；明显不是对话用的（嵌入、语音、审核等）过滤掉。
enum ModelList {
    static func newestFirst(_ names: [String]) -> [String] {
        let skip = ["embed", "tts", "whisper", "audio", "transcri", "moderation", "rerank", "realtime", "search", "dall-e", "speech"]
        let usable = names.filter { name in !skip.contains { name.lowercased().contains($0) } }
        return usable.sorted { a, b in
            let x = numbers(a), y = numbers(b)
            for (p, q) in zip(x, y) where p != q { return p > q }
            return x.count != y.count ? x.count > y.count : a < b
        }
    }
    private static func numbers(_ name: String) -> [Int] {
        name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
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
    var generation: GenerationProposal? = nil
}
