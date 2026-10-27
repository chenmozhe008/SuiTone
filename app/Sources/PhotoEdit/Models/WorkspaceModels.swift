import Foundation

enum AdjustmentScope:String,CaseIterable {
    case all,selected,current
    var title:String {switch self {case .all:return "整批";case .selected:return "所选";case .current:return "当前"}}
}

struct WorkspaceChange {
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

struct StylePreset:Identifiable {
    let id:String
    let title:String
    let detail:String
    let icon:String
    static let all:[StylePreset]=[
        .init(id:"smart",title:"智能自然",detail:"按照片自动判断",icon:"sparkles"),
        .init(id:"clean",title:"清透",detail:"明亮、轻对比",icon:"sun.max"),
        .init(id:"soft",title:"柔和",detail:"柔光、低反差",icon:"cloud.sun"),
        .init(id:"warm",title:"暖调",detail:"温暖、克制",icon:"sun.haze"),
        .init(id:"cool",title:"冷调",detail:"清冷、安静",icon:"moon"),
        .init(id:"mono",title:"黑白",detail:"光影与纹理",icon:"circle.lefthalf.filled"),
        .init(id:"vivid",title:"鲜明",detail:"色彩、层次",icon:"circle.lefthalf.filled"),
        .init(id:"airy",title:"轻盈",detail:"明亮、淡彩",icon:"cloud.sun"),
        .init(id:"cinema",title:"青橙电影",detail:"冷影、暖光",icon:"film"),
        .init(id:"film",title:"暖胶片",detail:"暖色、柔高光",icon:"camera"),
        .init(id:"neon",title:"霓虹夜色",detail:"蓝紫、洋红",icon:"moon.stars"),
        .init(id:"vintage",title:"复古褪色",detail:"褪黑、黄绿底色",icon:"camera.aperture"),
        .init(id:"editorial",title:"低饱和叙事",detail:"冷影、克制颜色",icon:"film.stack"),
        .init(id:"noir",title:"高反差黑白",detail:"深黑、强反差",icon:"circle.lefthalf.filled"),
        .init(id:"golden",title:"金色时刻",detail:"琥珀暖光、褪黑",icon:"sun.haze"),
        .init(id:"bleach",title:"银幕冷调",detail:"冷色、硬朗光影",icon:"film")
    ]
    var creative:Bool {!["smart","clean","soft","warm","cool","mono","vivid","airy"].contains(id)}
}

struct AssistantProvider:Decodable,Identifiable {
    var id:String
    var title:String
    var available:Bool
}

struct ChatMessage:Identifiable {
    let id=UUID()
    var role:String
    var text:String
    var notes:[String]=[]
    var affectedPhotos:[String]=[]
}

struct AssistantChange:Decodable {
    var id:String
    var params:AdjustmentParameters
    var notes:[String]
}

struct AssistantJob:Decodable {
    var state:String
    var reply:String?
    var selection:String?
    var changes:[AssistantChange]?
    var error:String?
}
