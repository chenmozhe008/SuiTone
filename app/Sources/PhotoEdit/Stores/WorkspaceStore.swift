import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class WorkspaceStore {
    let engine: EngineClient
    init(engine: EngineClient = EngineClient()) { self.engine = engine }
    var photos: [PhotoRecord] = []
    var references: [ImportedPhoto] = []
    var referenceScopes: [String: String] = [:]
    var selectedIDs: Set<String> = []
    var currentID: String?
    var analysis: AnalysisResponse?
    var analysisError: String?
    var analysisAssetID: String?
    var analysisRequestID = UUID()
    var overlay = ""
    var manualOverlay: String?
    /// 局部区域的轮廓图（透明底，只画边缘），选中区域时常驻显示
    var localOutline: String?
    var overlayPreviewTask: Task<Void, Never>?
    var showOriginal = false
    /// 左右滑动对比：左侧原图、右侧调整后；splitPosition 为分隔线位置（0–1）。
    var splitCompare = false
    var splitPosition = 0.5
    var grid = false
    var busy = false
    var importing = false
    var batchWorking = false
    var rendering = false
    var progressDone = 0
    var progressTotal = 0
    /// 右栏：chat / adjust 两页常驻；repair / quality 由画布工具栏进入，完成后回到 lastMainTab。
    var inspectorTab = "adjust"
    var lastMainTab = "adjust"
    /// 调整页「局部」里选中的区域（water / sky / land / person）。
    var localRegion: String?
    var myStyles: [MyStyle] = {
        guard let data = UserDefaults.standard.data(forKey: "myStyles") else { return [] }
        return (try? JSONDecoder().decode([MyStyle].self, from: data)) ?? []
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(myStyles), forKey: "myStyles") }
    }
    var styleFamily = "creative"
    var styles: [StylePreset] = []
    var imageServices: [ImageService] = []
    var imageService = UserDefaults.standard.string(forKey: "imageService") ?? "" {
        didSet { UserDefaults.standard.set(imageService, forKey: "imageService") }
    }
    var imageModels: [String: String] = (UserDefaults.standard.dictionary(forKey: "imageModels") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(imageModels, forKey: "imageModels") }
    }
    /// 设置窗口：nil 关闭，"chat" 对话和看图，"image" AI 改图（所有入口都打开这一个窗口）
    var settingsTab: String?
    /// 看图测试结果，键为「服务商|模型」；没测过的不在里面（界面写「看图未验证」）
    var visionChecks: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "visionChecks") as? [String: Bool]) ?? [:] {
        didSet { UserDefaults.standard.set(visionChecks, forKey: "visionChecks") }
    }
    var generationTask: Task<Void, Never>?
    /// AI 改图面板最近一次生成对应的对话消息（面板显示它的进度和结果）
    var aiEditMessageID: UUID?
    /// 在画布上临时查看某个版本（不改照片，点「回到当前」或离开面板即恢复）
    var versionPreview: String?
    /// 验收截图用：启动参数 `-aiRefs` 带进来的参考图，进 AI 改图面板时自动填上
    var aiEditReferences: [String] = []
    /// 验收截图用：`-aiMention` 时自动在输入框里插一个图片块并弹出 @ 列表
    var aiMentionDemo = false
    /// 验收截图用：`-aiGenerate` 时自动用插入的图片块跑一次真实生成
    var aiAutoPrompt = false
    /// 出图服务是否已配好（密钥只在真正生成时才读钥匙串，这里看保存标记，避免弹授权框）
    var imageServiceReady: Bool {
        guard let service = imageServices.first(where: { $0.id == imageService }) else { return false }
        return service.id == "mock" || UserDefaults.standard.bool(forKey: "imageKeySaved." + service.id)
    }

    /// 当前服务当前型号还能加几张参考图。数字来自引擎（照服务商官方文档），界面不自己定；
    /// 拿不到就当 0 张，宁可不加也不发出去被拒。
    var imageReferenceLimit: Int {
        guard let service = imageServices.first(where: { $0.id == imageService }) else { return 0 }
        let model = imageModels[service.id] ?? service.defaultModel
        return service.referenceLimits[model] ?? 0
    }

    /// 当前用的出图模型名（提示用）
    var imageModelName: String {
        guard let service = imageServices.first(where: { $0.id == imageService }) else { return "" }
        return imageModels[service.id] ?? service.defaultModel
    }
    var styleTiles: [String:String] = [:]
    var styleTileTask: Task<Void,Never>?
    var status = "正在检查本地引擎…"
    var error: String?
    var matchNotes: [String] = []
    var matchOnly = "all"
    var previewMilliseconds: Double?
    var selectionBox: [Double]?
    /// 修复选法：brush 画笔 / lasso 套索 / object 点选物体 / box 方框
    var repairTool = "brush"
    var repairStrokes: [[[Double]]] = []
    var repairPolygon: [[Double]] = []
    var repairPoint: [Double]?
    var brushSize = 0.025
    /// 多笔选区：已画好的各笔（选区、移除、AI 改图三页共用）
    var selectionParts: [SelectionPart] = []
    /// 工具条上选的是「减去」；按住 ⌥ 也临时算减去
    var selectionSubtract = false
    /// 方框选法拖动中的框（松手才变成一笔）
    var selectionDraftBox: [Double]?
    /// 引擎合成后的选区样子（透明底，选中部分半透明填充＋白边）
    var selectionOverlay: String?
    /// 当前 overlay 的标注色：red 普通选区 / cyan AI 改图页的选区（画面重点，颜色区分）
    var selectionOverlayColor = "red"
    /// 正在继续编辑的已保存选区（局部调整里的手动选区）
    var editingSelectionKey: String?
    var selectionRevision = 0
    var repairMode = "box"
    var repairClasses = "railing, fence"
    var repairEnabled = false
    var repairMaskOverlay: String?
    var cutoutPreview: String?
    var cutoutSnapshot: EditSnapshot?
    var repairDraft: RepairDraft?
    var repairShowingBefore = false
    var repairRevision = 0
    var exportOptions = ExportOptions()
    var showExportOptions = false
    var lastExport: String?
    var undoChanges: [WorkspaceChange] = []
    var redoChanges: [WorkspaceChange] = []
    /// 图集（导入批次）记录：关掉应用再打开还在，跟 Lightroom 的目录一样。
    var albums: [LibraryAlbum] = []
    var currentAlbumID: String?
    var albumSteps: [LibraryStep] = []
    var showLibrary = true
    var libraryTask: Task<Void, Never>?
    /// 只在单元测试里设置：把图集写到指定目录，几个测试并行时不互相踩。
    var libraryDirectory: URL?
    /// 拖动自由旋转时的临时角度（度）：画面先在本地实时跟着转，松手才让引擎精确渲染
    var angleDraft: Double = 0
    /// 裁切页正在框的范围（0–1 比例）和拖拽起点；裁切比例选的是哪一档
    var cropDraft: [Double]?
    var cropAnchor: [Double]?
    var cropAspect = "original"
    var providers: [AssistantProvider] = []
    var assistantProvider = UserDefaults.standard.string(forKey: "assistantProvider") ?? "codex" {
        didSet { UserDefaults.standard.set(assistantProvider, forKey: "assistantProvider") }
    }
    /// 已从钥匙串读出的密钥，按服务商缓存；只在选中该服务商时读取，避免反复弹钥匙串授权。
    var apiKeys: [String: String] = [:]
    var apiModels: [String: String] = (UserDefaults.standard.dictionary(forKey: "apiModels") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(apiModels, forKey: "apiModels") }
    }
    var customBaseURL: String = UserDefaults.standard.string(forKey: "customBaseURL") ?? "" {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: "customBaseURL") }
    }
    /// 对话调整必须看图；用户对每个服务商同意一次后记住。
    var visionConsents: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "visionConsents") ?? []) {
        didSet { UserDefaults.standard.set(Array(visionConsents).sorted(), forKey: "visionConsents") }
    }
    var visionEnabled: Bool { visionConsents.contains(assistantProvider) }
    var currentProvider: AssistantProvider? { providers.first { $0.id == assistantProvider } }
    var usesAPI: Bool { currentProvider?.isAPI ?? false }

    func loadAPIKey() {
        guard usesAPI, apiKeys[assistantProvider] == nil else { return }
        let key = Keychain.read(assistantProvider) ?? ""
        apiKeys[assistantProvider] = key
        if !key.isEmpty { UserDefaults.standard.set(true, forKey: "apiKeySaved." + assistantProvider) }
        // 旧版（临时签名）存的条目只认旧程序，每次启动都会弹授权框；读出后用当前签名重存一次，之后不再询问。
        let migrated = "keychainResaved." + assistantProvider
        if !key.isEmpty && !UserDefaults.standard.bool(forKey: migrated) && Keychain.save(key, for: assistantProvider) {
            UserDefaults.standard.set(true, forKey: migrated)
        }
    }

    /// 哪些 API 服务存过密钥（只看标记，不读钥匙串，避免为显示状态弹授权框）
    func apiKeySaved(_ provider: String) -> Bool {
        UserDefaults.standard.bool(forKey: "apiKeySaved." + provider) || !(apiKeys[provider] ?? "").isEmpty
    }

    func saveAPISettings(provider: String, key: String?, model: String, baseURL: String) {
        if let key {
            Keychain.save(key, for: provider); apiKeys[provider] = key
            UserDefaults.standard.set(!key.isEmpty, forKey: "apiKeySaved." + provider)
        }
        apiModels[provider] = model
        if provider == "custom" { customBaseURL = baseURL }
    }

    /// 当前服务商需要的接入参数；本机账号返回 nil。API 缺密钥、模型或地址时视为未配置。
    var apiCredentials: APICredentials? {
        guard let provider = currentProvider, provider.isAPI else { return nil }
        let model = apiModels[provider.id] ?? provider.models.first ?? ""
        return APICredentials(key: apiKeys[provider.id] ?? "", model: model, baseURL: provider.needsBaseUrl ? customBaseURL : "")
    }

    var assistantReady: Bool {
        guard let provider = currentProvider, provider.available else { return false }
        guard provider.isAPI else { return true }
        guard let credentials = apiCredentials, !credentials.key.isEmpty, !credentials.model.isEmpty else { return false }
        return !provider.needsBaseUrl || !credentials.baseURL.isEmpty
    }
    var suggestions: [SuggestionCard] = []
    var suggestionSource = "local"
    var aiSuggestionCache: [String: [SuggestionCard]] = [:]
    var chatDraft = ""
    var chatMessages: [ChatMessage] = []
    var variantApplied: [UUID: [EditSnapshot]] = [:]
    var chatting = false
    var assistantJobID: String?
    var assistantCancellationRequested = false
    var assistantApplying = false
    var assistantPhase = ""
    var importTask: Task<Void, Never>?
    var batchTask: Task<Void, Never>?
    var assistantTask: Task<Void, Never>?
    var editingOrigin: EditSnapshot?
    var editingPhoto: String?
    var previewVersion = 0
    var previewTask: Task<Void, Never>?
    var analysisTask: Task<Void, Never>?

    var currentIndex: Int? { photos.firstIndex { $0.id == currentID } }
    var current: PhotoRecord? { currentIndex.map { photos[$0] } }
    var selected: [PhotoRecord] { photos.filter { selectedIDs.contains($0.id) && !$0.excluded } }
    var included: [PhotoRecord] { photos.filter { !$0.excluded } }
    /// 默认只改当前照片；在选片条里多选（含当前照片）后，改动作用于所选。
    var targets: [PhotoRecord] {
        guard let current, !current.excluded else { return [] }
        let chosen = selected
        return chosen.count > 1 && selectedIDs.contains(current.id) ? chosen : [current]
    }
    var scopeLabel: String { targets.count > 1 ? "所选 \(targets.count) 张" : "当前照片" }
    var canUndo: Bool { !undoChanges.isEmpty }
    var canRedo: Bool { !redoChanges.isEmpty }
    var controlsBlocked: Bool { busy || importing || batchWorking || repairDraft != nil }
    var batchProgress: Bool { importing || batchWorking }

    func start() async {
        do {
            let missing = try await engine.health()
            if missing.isEmpty { status = "就绪" }
            else { error = "缺少模型：\n" + missing.joined(separator: "\n") + "\n请按 engine/README.md 下载；已有模型不会被替换。" }
            struct Providers: Decodable { var providers: [AssistantProvider] }
            let response: Providers = try await engine.get("assistant-providers")
            providers = response.providers
            struct Services: Decodable { var services: [ImageService] }
            let showMock = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["mockImageService"] != nil
            imageServices = ((try? await engine.get("image-services") as Services)?.services ?? []).filter { $0.id != "mock" || showMock }
            struct Styles: Decodable { var styles: [StylePreset] }
            styles = (try await engine.get("styles") as Styles).styles
            if !providers.contains(where: { $0.id == assistantProvider && $0.available }),
               let first = providers.first(where: \.available) { assistantProvider = first.id }
            loadAPIKey()
            applyLaunchOptions()
            // 上次关掉时正在弄的那批照片，重新打开就接着弄；图集列表也一并读回来。
            // 用命令行指定了要导入的图时（验收截图）不自动打开，免得把刚导入的顶掉。
            loadLibrary()
            if UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["importOnLaunch"] == nil,
               let recent = albums.first { openAlbum(recent) }
        } catch { self.error = error.localizedDescription; status = "引擎未就绪" }
    }

    /// 验收截图用：`open SuiTone.app --args -importOnLaunch "a.jpg|b.jpg" -openTab adjust -selectCount 2 -localRegion sky`。
    /// 参数只来自本次启动命令行（NSArgumentDomain），不写入偏好设置。
    func applyLaunchOptions() {
        let options = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let paths = options["importOnLaunch"] as? String else { return }
        importURLs(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
        Task {
            for _ in 0..<120 where !(photos.count >= 1 && photos.allSatisfy(\.ready) && !importing) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            grid = false
            if let size = (options["windowSize"] as? String)?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = NSApp.windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: size[0], height: size[1] + 28)), display: true)
            }
            if let count = Int(options["selectCount"] as? String ?? ""), count > 1 {
                selectedIDs = Set(photos.prefix(count).map(\.id)); activate(photos.first?.id)
            }
            if let tab = options["openTab"] as? String { inspectorTab = tab }
            if let settings = options["openSettings"] as? String { settingsTab = settings }
            // 验收 AI 改图面板用：直接带上参考图，省得每次手点。`-aiRefs "a.jpg|b.jpg"`
            if let refs = options["aiRefs"] as? String {
                aiEditReferences = refs.split(separator: "|").map(String.init).filter { !$0.isEmpty }
            }
            if options["aiMention"] != nil { aiMentionDemo = true }
            if options["aiGenerate"] != nil { aiAutoPrompt = true }
            if let point = (options["selectionPoint"] as? String)?.split(separator: ",").compactMap({ Double($0) }), point.count == 2 {
                try? await Task.sleep(for: .milliseconds(500))
                repairTool = "object"; repairPoint = point; commitSelectionPart()
            }
            if let region = options["localRegion"] as? String {
                loadAnalysis(); try? await Task.sleep(for: .seconds(2)); selectLocalRegion(region)
            }
        }
    }

    func activate(_ id: String?) {
        finishEditing()
        repairRevision += 1; repairDraft = nil; repairShowingBefore = false
        let firstSelected = selected.count > 1 && id.map { selectedIDs.contains($0) } == true ? selected.first?.id : id
        currentID = firstSelected; analysis = nil; overlay = ""; clearRepairSelection(); localRegion = nil
        analysisTask?.cancel(); analysisTask = nil; analysisAssetID = nil; analysisError = nil
        guard current != nil else { return }
        styleTiles=[:]
        if current?.ready == true { schedulePreview(); loadStyleTiles(); loadAnalysis() }
    }

    func loadAnalysis() {
        guard let photo = current, photo.ready else { return }
        if analysisTask != nil && analysisAssetID == photo.assetID { return }
        analysisTask?.cancel()
        let requestID = UUID()
        analysisRequestID = requestID
        analysisAssetID = photo.assetID
        analysisError = nil
        analysisTask = Task {
            defer {
                if analysisRequestID == requestID { analysisTask = nil; analysisAssetID = nil }
            }
            do {
                let response: AnalysisResponse = try await engine.request("analyze", body: ["id": photo.assetID])
                guard !Task.isCancelled, current?.assetID == photo.assetID, analysisRequestID == requestID else { return }
                analysis = response
            } catch {
                guard !Task.isCancelled, current?.assetID == photo.assetID, analysisRequestID == requestID else { return }
                analysisError = error.localizedDescription
            }
        }
    }

    func schedulePreview() {
        previewVersion += 1
        guard previewTask == nil else { return }
        previewTask = Task {
            rendering = true
            defer { previewTask = nil; rendering = false }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(65))
                let version = previewVersion
                guard let photo = current else { return }
                do {
                    let start = Date()
                    var previewParams = photo.parameters
                    // 裁切页要看到完整画面（含将被裁掉的部分），框才不会错位。
                    if inspectorTab == "crop" { previewParams.crop = nil }
                    let response: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID, "params": try EngineClient.object(previewParams), "quality": try EngineClient.object(photo.quality)])
                    if version == previewVersion, currentID == photo.id, let i = currentIndex, photos[i].quality == photo.quality {
                        photos[i].previewPath = response.preview
                        if photos[i].parameters.autoDehaze == true { photos[i].parameters.dehazeAmt = response.dehazeAmt }
                        previewMilliseconds = Date().timeIntervalSince(start) * 1000
                        if !batchProgress { status = "\(photo.lookName) · 预览 \(Int(previewMilliseconds ?? 0)) ms" }
                    }
                } catch { self.error = error.localizedDescription; return }
                if version == previewVersion { return }
            }
        }
    }

    func capture(_ records: [PhotoRecord]) -> [String: EditSnapshot] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.snapshot) })
    }

    @discardableResult func recordChange(_ label: String, before: [String: EditSnapshot]) -> UUID? {
        var old: [String: EditSnapshot] = [:], new: [String: EditSnapshot] = [:]
        for (id, origin) in before {
            guard let photo = photos.first(where: { $0.id == id }) else { continue }
            var previous = origin, now = photo.snapshot
            previous.label = label; now.label = label
            if previous != now { old[id] = previous; new[id] = now }
        }
        guard !old.isEmpty else { return nil }
        var change = WorkspaceChange(label: label, before: old, after: new)
        // 撤销栈只在本次运行有效；改动同时记进图集，重启后左侧「历史」里还能看到、能点回去。
        change.stepID = noteStep(label, after: new)
        undoChanges.append(change)
        if undoChanges.count > 100 { undoChanges.removeFirst() }
        redoChanges = []
        return change.id
    }

    func beginEditing(_ label: String = "调整参数") {
        guard editingOrigin == nil, let current else { return }
        var origin = current.snapshot; origin.label = label
        editingOrigin = origin; editingPhoto = current.id
    }

    func finishEditing() {
        defer { editingOrigin = nil; editingPhoto = nil }
        guard let origin = editingOrigin, let id = editingPhoto else { return }
        recordChange(origin.label, before: [id: origin])
    }

    func update(_ body: (inout AdjustmentParameters) -> Void) {
        guard let i = currentIndex else { return }
        let source = photos[i]
        var params = source.parameters; body(&params)
        var prepared = prepareParameters(params, name: "自定义", notes: source.notes, on: source)
        // 保留上一帧，直到新预览就绪，避免拖动时闪回原图。
        prepared.previewPath = source.previewPath
        guard commitPrepared(prepared, expected: source.snapshot) else { return }
        overlay = ""; showOriginal = false; schedulePreview()
    }

    func change(_ label: String, _ body: (inout AdjustmentParameters) -> Void) {
        beginEditing(label); update(body); finishEditing()
    }

    func applySnapshot(_ snapshot: EditSnapshot) {
        guard let i = currentIndex else { return }
        applyStates([photos[i].id: snapshot])
    }

    func applyStates(_ states: [String: EditSnapshot]) {
        for i in photos.indices {
            guard let snapshot = states[photos[i].id] else { continue }
            photos[i].assetID = snapshot.assetID; photos[i].parameters = snapshot.parameters
            photos[i].operations = snapshot.operations; photos[i].lookName = snapshot.lookName
            photos[i].notes = snapshot.notes; photos[i].previewPath = nil
            photos[i].quality = snapshot.quality
        }
        overlay = ""; showOriginal = false; analysis = nil
        schedulePreview()
        if grid { refreshGrid() }
    }

    func undo() {
        finishEditing()
        guard let last = undoChanges.popLast() else { return }
        for i in chatMessages.indices where chatMessages[i].changeID == last.id { chatMessages[i].wasUndone = true }
        redoChanges.append(last); applyStates(last.before)
        if let stepID = last.stepID { albumSteps.removeAll { $0.id == stepID } }
        syncAlbum()
        syncAlbum()
        status = "已撤销：\(last.label) · \(last.before.count) 张"
    }

    func redo() {
        guard var next = redoChanges.popLast() else { return }
        for i in chatMessages.indices where chatMessages[i].changeID == next.id { chatMessages[i].wasUndone = false }
        applyStates(next.after)
        next.stepID = noteStep(next.label, after: next.after)
        undoChanges.append(next)
        status = "已重做：\(next.label) · \(next.after.count) 张"
    }

    func snapshot() {
        finishEditing()
        guard let i = currentIndex else { return }
        var snapshot = photos[i].snapshot
        snapshot.label = "快照 " + Date().formatted(date: .omitted, time: .shortened)
        photos[i].snapshots.append(snapshot)
        status = "已保存当前照片快照"
    }

    func restoreSnapshot(_ snapshot: EditSnapshot) {
        beginEditing("恢复快照"); applySnapshot(snapshot); finishEditing()
    }

    func toggleStar(_ id: String) {
        if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].starred.toggle() }
        syncAlbum()
    }
    func toggleExcluded(_ id: String) {
        if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].excluded.toggle() }
        syncAlbum()
    }

    func selectPhoto(_ id: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let start = photos.firstIndex(where: { $0.id == currentID }), let end = photos.firstIndex(where: { $0.id == id }) {
            let range = Set(photos[min(start,end)...max(start,end)].map(\.id))
            selectedIDs = modifiers.contains(.command) ? selectedIDs.union(range) : range
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else { selectedIDs = [id] }
        let first = selected.first?.id
        activate(selected.count > 1 ? first : (selectedIDs.contains(id) ? id : first))
    }
}
