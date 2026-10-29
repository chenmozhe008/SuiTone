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
    var overlay = ""
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
    var scope: AdjustmentScope = .all
    var inspectorTab = "start"
    var styleFamily = "creative"
    var styleTiles: [String:String] = [:]
    var styleTileTask: Task<Void,Never>?
    var status = "正在检查本地引擎…"
    var error: String?
    var matchNotes: [String] = []
    var matchOnly = "all"
    var previewMilliseconds: Double?
    var selectionBox: [Double]?
    var repairMode = "box"
    var repairClasses = "railing, fence"
    var repairEnabled = false
    var repairMaskOverlay: String?
    var repairDraft: RepairDraft?
    var repairShowingBefore = false
    var repairRevision = 0
    var exportOptions = ExportOptions()
    var showExportOptions = false
    var lastExport: String?
    var undoChanges: [WorkspaceChange] = []
    var redoChanges: [WorkspaceChange] = []
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
        apiKeys[assistantProvider] = Keychain.read(assistantProvider) ?? ""
    }

    func saveAPISettings(provider: String, key: String?, model: String, baseURL: String) {
        if let key { Keychain.save(key, for: provider); apiKeys[provider] = key }
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
    var aiSuggestionCache: [String: [SuggestionCard]] = [:]
    var chatDraft = ""
    var chatMessages: [ChatMessage] = []
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
    var targets: [PhotoRecord] {
        switch scope {
        case .all: return included
        case .selected: return selected
        case .current: return current.map { $0.excluded ? [] : [$0] } ?? []
        }
    }
    var scopeLabel: String { "\(scope.title) \(targets.count) 张" }
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
            if !providers.contains(where: { $0.id == assistantProvider && $0.available }),
               let first = providers.first(where: \.available) { assistantProvider = first.id }
            loadAPIKey()
        } catch { self.error = error.localizedDescription; status = "引擎未就绪" }
    }

    func activate(_ id: String?) {
        finishEditing()
        repairRevision += 1; repairDraft = nil; repairShowingBefore = false
        currentID = id; analysis = nil; overlay = ""; selectionBox = nil; repairMaskOverlay = nil
        analysisTask?.cancel()
        guard current != nil else { return }
        styleTiles=[:]
        if current?.ready == true { schedulePreview(); loadStyleTiles() }
    }

    func loadAnalysis() {
        guard let photo = current else { return }
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                let response: AnalysisResponse = try await engine.request("analyze", body: ["id": photo.assetID])
                guard !Task.isCancelled, current?.assetID == photo.assetID else { return }
                analysis = response
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
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
                    let response: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID, "params": try EngineClient.object(photo.parameters), "quality": try EngineClient.object(photo.quality)])
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
        let change = WorkspaceChange(label: label, before: old, after: new)
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
        status = "已撤销：\(last.label) · \(last.before.count) 张"
    }

    func redo() {
        guard let next = redoChanges.popLast() else { return }
        for i in chatMessages.indices where chatMessages[i].changeID == next.id { chatMessages[i].wasUndone = false }
        undoChanges.append(next); applyStates(next.after)
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

    func toggleStar(_ id: String) { if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].starred.toggle() } }
    func toggleExcluded(_ id: String) { if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].excluded.toggle() } }

    func selectPhoto(_ id: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let start = photos.firstIndex(where: { $0.id == currentID }), let end = photos.firstIndex(where: { $0.id == id }) {
            let range = Set(photos[min(start,end)...max(start,end)].map(\.id))
            selectedIDs = modifiers.contains(.command) ? selectedIDs.union(range) : range
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else { selectedIDs = [id] }
        activate(selectedIDs.contains(id) ? id : photos.first(where: { selectedIDs.contains($0.id) })?.id)
    }
}
