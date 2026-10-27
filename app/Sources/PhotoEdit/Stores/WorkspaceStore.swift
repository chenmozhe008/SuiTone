import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class WorkspaceStore {
    let engine = EngineClient()
    var photos: [PhotoRecord] = []
    var references: [ImportedPhoto] = []
    var referenceScopes: [String: String] = [:]
    var selectedIDs: Set<String> = []
    var currentID: String?
    var analysis: AnalysisResponse?
    var overlay = ""
    var showOriginal = false
    var grid = false
    var busy = false
    var rendering = false
    var status = "正在检查本地引擎…"
    var error: String?
    var matchNotes: [String] = []
    var matchOnly = "all"
    var previewMilliseconds: Double?
    var selectionBox: [Double]?
    var repairMode = "keepSky"
    var repairClasses = "railing, fence"
    var repairEnabled = false
    var repairMaskOverlay: String?
    var exportOptions = ExportOptions()
    var showExportOptions = false
    var lastExport: String?
    private var editingOrigin: EditSnapshot?
    private var editingPhoto: String?
    private var previewVersion = 0
    private var previewTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    var currentIndex: Int? { photos.firstIndex { $0.id == currentID } }
    var current: PhotoRecord? { currentIndex.map { photos[$0] } }
    var selected: [PhotoRecord] { photos.filter { selectedIDs.contains($0.id) && !$0.excluded } }
    var canUndo: Bool { !(current?.history.isEmpty ?? true) }
    var canRedo: Bool { !(current?.future.isEmpty ?? true) }

    func start() async {
        do {
            let missing = try await engine.health()
            if missing.isEmpty { status = "本地引擎就绪 · 照片仅在本机处理" }
            else { error = "缺少模型：\n" + missing.joined(separator: "\n") + "\n请按 engine/README.md 下载；已有模型不会被替换。" }
        } catch { self.error = error.localizedDescription; status = "引擎未就绪" }
    }

    func chooseImport(reference: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !reference
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = reference ? "选择参考图，只学习颜色与影调" : "选择照片或文件夹，原图保持不变"
        if panel.runModal() == .OK { importURLs(panel.urls, reference: reference) }
    }

    func importURLs(_ urls: [URL], reference: Bool = false) {
        guard !busy else { return }
        busy = true; status = reference ? "正在读取参考图…" : "正在读取照片…"
        Task {
            defer { busy = false }
            do {
                let result: ImportResponse = try await engine.request("import", body: ["paths": urls.map(\.path)])
                if reference {
                    for item in result.photos where !references.contains(where: { $0.id == item.id }) { references.append(item) }
                } else {
                    for item in result.photos where !photos.contains(where: { $0.id == item.id }) {
                        photos.append(PhotoRecord(imported: item, assetID: item.id))
                    }
                    if currentID == nil, let first = photos.first { selectedIDs = [first.id]; activate(first.id) }
                }
                status = "已读取 \(result.photos.count) 张\(reference ? "参考图" : "照片")"
                if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
            } catch { self.error = error.localizedDescription }
        }
    }

    func activate(_ id: String?) {
        finishEditing()
        currentID = id; analysis = nil; overlay = ""; selectionBox = nil; repairMaskOverlay = nil
        analysisTask?.cancel()
        guard let photo = current else { return }
        analysisTask = Task {
            do {
                let response: AnalysisResponse = try await engine.request("analyze", body: ["id": photo.assetID])
                guard !Task.isCancelled, current?.assetID == photo.assetID else { return }
                analysis = response
                status = "分区已缓存 · 可查看识别选区"
                schedulePreview()
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
                    let response: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID, "params": try EngineClient.object(photo.parameters)])
                    if version == previewVersion, currentID == photo.id, let i = currentIndex {
                        photos[i].previewPath = response.preview
                        if photos[i].parameters.autoDehaze==true {photos[i].parameters.dehazeAmt=response.dehazeAmt}
                        previewMilliseconds = response.renderMs
                        status = "预览 \(Int(response.renderMs)) ms · 识别结果已复用"
                    }
                } catch { self.error = error.localizedDescription; return }
                if version == previewVersion { return }
            }
        }
    }

    func beginEditing(_ label: String = "调整参数") {
        guard editingOrigin == nil, let current else { return }
        var origin = current.snapshot; origin.label = label
        editingOrigin = origin; editingPhoto = current.id
    }

    func finishEditing() {
        defer { editingOrigin = nil; editingPhoto = nil }
        guard let origin = editingOrigin, let index = photos.firstIndex(where: { $0.id == editingPhoto }) else { return }
        var now = photos[index].snapshot; now.label = origin.label
        if now != origin { photos[index].history.append(origin); photos[index].future = [] }
    }

    func update(_ body: (inout AdjustmentParameters) -> Void) {
        guard let i = currentIndex else { return }
        body(&photos[i].parameters); overlay = ""; schedulePreview()
    }

    func change(_ label: String, _ body: (inout AdjustmentParameters) -> Void) {
        beginEditing(label); update(body); finishEditing()
    }

    func applySnapshot(_ snapshot: EditSnapshot) {
        guard let i = currentIndex else { return }
        let changed = photos[i].assetID != snapshot.assetID
        photos[i].assetID = snapshot.assetID; photos[i].parameters = snapshot.parameters
        photos[i].operations = snapshot.operations
        if changed { activate(currentID) } else { schedulePreview() }
    }

    func undo() {
        finishEditing()
        guard let i = currentIndex, let last = photos[i].history.popLast() else { return }
        photos[i].future.append(photos[i].snapshot); applySnapshot(last)
    }

    func redo() {
        guard let i = currentIndex, let next = photos[i].future.popLast() else { return }
        photos[i].history.append(photos[i].snapshot); applySnapshot(next)
    }

    func snapshot() {
        finishEditing()
        guard let i = currentIndex else { return }
        var snapshot = photos[i].snapshot
        snapshot.label = "快照 " + Date().formatted(date: .omitted, time: .shortened)
        photos[i].snapshots.append(snapshot)
    }

    func restoreSnapshot(_ snapshot: EditSnapshot) {
        beginEditing("恢复快照"); applySnapshot(snapshot); finishEditing()
    }

    func match() {
        guard let photo = current, !references.isEmpty, !busy else { return }
        finishEditing(); busy = true; status = "正在按区域学习参考图…"
        Task {
            defer { busy = false }
            do {
                var body: [String: Any] = ["id": photo.assetID, "references": references.map(\.id), "params": try EngineClient.object(photo.parameters), "reference_scopes": referenceScopes]
                if matchOnly != "all" { body["only"] = matchOnly }
                let result: MatchResponse = try await engine.request("match", body: body)
                guard currentID == photo.id else { return }
                change("参考图反推") { $0 = result.params }
                matchNotes = result.notes
                status = result.learned.isEmpty ? "没有共同的可靠区域，设置保持不变" : "已学习：" + result.learned.map(RegionNames.title).joined(separator: "、")
            } catch { self.error = error.localizedDescription }
        }
    }

    func synchronize(keepDehaze: Bool = true) {
        finishEditing()
        guard let source = current, selected.count > 1 else { return }
        for i in photos.indices where selectedIDs.contains(photos[i].id) && photos[i].id != source.id && !photos[i].excluded {
            var old = photos[i].snapshot; old.label = "同步调色参数"
            photos[i].history.append(old); photos[i].future = []
            let localDehaze = photos[i].parameters.dehazeAmt
            photos[i].parameters = source.parameters
            if keepDehaze { photos[i].parameters.dehazeAmt = localDehaze }
            photos[i].previewPath = nil
        }
        status = "已同步到 \(selected.count) 张 · 保留每张去雾强度"
        if grid { refreshGrid() }
    }

    func refreshGrid() {
        let ids = selected.map(\.id)
        Task {
            for id in ids {
                guard let photo = photos.first(where: { $0.id == id }) else { continue }
                do {
                    let result: PreviewResponse = try await engine.request("preview", body: ["id": photo.assetID, "params": try EngineClient.object(photo.parameters)])
                    if let i = photos.firstIndex(where: { $0.id == id }), photos[i].parameters == photo.parameters { photos[i].previewPath = result.preview }
                } catch { self.error = error.localizedDescription; return }
            }
        }
    }

    func remove() {
        guard let photo = current, let box = selectionBox, !busy else { return }
        let operation = RemovalOperation(box: box, classes: repairMode == "classes" ? repairClasses.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil,
                                         keep: repairMode == "keepSky" ? ["sky"] : nil)
        busy = true; status = "正在修补框选区域…"
        Task {
            defer { busy = false }
            do {
                var body = try EngineClient.object(operation); body["id"] = photo.assetID
                let result: RemoveResponse = try await engine.request("remove", body: body)
                guard currentID == photo.id, let i = currentIndex else { return }
                beginEditing("去杂物")
                photos[i].assetID = result.id; photos[i].operations.append(operation)
                finishEditing(); selectionBox = nil; repairEnabled = false; repairMaskOverlay = nil; activate(photo.id)
            } catch { self.error = error.localizedDescription }
        }
    }

    func previewRepairMask() {
        guard let photo=current,let box=selectionBox,!busy else{return}
        let operation=RemovalOperation(box:box,classes:repairMode=="classes" ? repairClasses.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)}:nil,
                                       keep:repairMode=="keepSky" ? ["sky"]:nil)
        busy=true
        Task {
            defer{busy=false}
            do {
                struct Mask:Decodable{var overlay:String;var pixels:Int}
                var body=try EngineClient.object(operation);body["id"]=photo.assetID
                let result:Mask=try await engine.request("repair-mask",body:body)
                if currentID==photo.id {repairMaskOverlay=result.overlay;status="红色是将被修补的区域，请确认边界"}
            } catch {self.error=error.localizedDescription}
        }
    }

    func toggleStar(_ id: String) { if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].starred.toggle() } }
    func toggleExcluded(_ id: String) { if let i = photos.firstIndex(where: { $0.id == id }) { photos[i].excluded.toggle() } }

    func selectPhoto(_ id:String,modifiers:NSEvent.ModifierFlags) {
        if modifiers.contains(.shift),let start=photos.firstIndex(where:{$0.id==currentID}),let end=photos.firstIndex(where:{$0.id==id}) {
            let range=Set(photos[min(start,end)...max(start,end)].map(\.id))
            selectedIDs=modifiers.contains(.command) ? selectedIDs.union(range):range
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(id) {selectedIDs.remove(id)} else {selectedIDs.insert(id)}
        } else {selectedIDs=[id]}
        activate(selectedIDs.contains(id) ? id:photos.first(where:{selectedIDs.contains($0.id)})?.id)
    }

    func export() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.message = "在所选位置内新建版本文件夹，已有文件保持不变"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let items = selected
        guard !items.isEmpty else { return }
        busy = true; showExportOptions = false; status = "正在全尺寸导出，修补和放大会需要更久…"
        Task {
            defer { busy = false }
            let progressTask=Task {
                while !Task.isCancelled {
                    if let (done,total,name)=try? await engine.progress(),total>0 {
                        status="全尺寸导出 \(min(done+1,total))/\(total) · \(name)"
                    }
                    try? await Task.sleep(for:.seconds(1))
                }
            }
            defer {progressTask.cancel()}
            do {
                let body: [String: Any] = ["items": try items.map { ["id": $0.assetID, "params": try EngineClient.object($0.parameters)] },
                                           "destination": destination.path, "options": try EngineClient.object(exportOptions)]
                let result: ExportResponse = try await engine.request("export", body: body)
                lastExport = result.directory; status = "已导出 \(result.files.count) 张到新版本文件夹"
            } catch { self.error = error.localizedDescription }
        }
    }

    func saveProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "照片调整-\(Int(Date().timeIntervalSince1970)).photoedit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = ProjectRecipe(photos: photos.map { ProjectPhoto(path: $0.imported.path, params: $0.parameters, operations: $0.operations) }, options: exportOptions)
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(project).write(to: url, options: .withoutOverwriting)
            status = "已保存调整记录，原图保持不变"
        } catch { self.error = error.localizedDescription }
    }

    func openProject(_ inputURL:URL? = nil) {
        let url:URL
        if let inputURL {url=inputURL}
        else {
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK,let chosen=panel.url else{return}
            url=chosen
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                let project = try decoder.decode(ProjectRecipe.self, from: Data(contentsOf: url))
                guard project.version == 1 else { throw EngineError(message: "无法读取此版本的调整记录") }
                let result: ImportResponse = try await engine.request("import", body: ["paths": project.photos.map(\.path)])
                var records: [PhotoRecord] = []
                for item in result.photos {
                    guard let saved = project.photos.first(where: { $0.path == item.path }) else { continue }
                    struct Restored: Decodable { var id: String }
                    let response: Restored = try await engine.request("restore", body: ["path": item.path,"operations": try saved.operations.map(EngineClient.object)])
                    var record = PhotoRecord(imported: item, assetID: response.id)
                    record.parameters = saved.params; record.operations = saved.operations; records.append(record)
                }
                photos = records; exportOptions = project.options
                selectedIDs = Set(records.prefix(1).map(\.id)); activate(records.first?.id)
                if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
            } catch { self.error = error.localizedDescription }
        }
    }
}
