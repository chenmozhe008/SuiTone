import Foundation

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor EngineClient {
    private var process: Process?
    private var input: Pipe?
    private var endpoint: URL?
    private let token = UUID().uuidString + UUID().uuidString
    private let session: URLSession = {
        let config=URLSessionConfiguration.ephemeral
        // loopback 始终直连；不把本地请求交给用户的系统代理。
        config.connectionProxyDictionary=[:]
        return URLSession(configuration:config)
    }()
    let root: URL

    init(root explicitRoot: URL? = nil) {
        if let explicitRoot {
            root = explicitRoot
        } else if let path = Bundle.main.object(forInfoDictionaryKey: "PhotoEditProjectRoot") as? String {
            root = URL(fileURLWithPath: path)
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
    }

    func start() throws {
        if process?.isRunning == true { return }
        let python = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/photo-edit/venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError(message: "找不到专用 Python 环境：\(python.path)。请按 engine/README.md 配置。")
        }
        let script = root.appendingPathComponent("engine/service.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw EngineError(message: "找不到项目引擎，请通过项目的一键运行脚本启动。")
        }
        let task = Process()
        task.executableURL = python
        task.arguments = ["-B", script.path, "--root", root.path]
        task.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PHOTO_EDIT_SESSION_TOKEN"] = token
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment
        let output = Pipe(), input = Pipe()
        task.standardOutput = output
        task.standardInput = input
        task.standardError = FileHandle.standardError
        try task.run()
        self.process = task
        self.input = input
        var line = Data()
        while line.count < 16384 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                throw EngineError(message: "本地引擎启动失败，请检查 Python 依赖与模型文件。")
            }
            if byte.first == 10 { break }
            line.append(byte)
        }
        struct Startup: Decodable { var port: Int }
        let startup = try JSONDecoder().decode(Startup.self, from: line)
        endpoint = URL(string: "http://127.0.0.1:\(startup.port)")
    }

    func request<T: Decodable>(_ path: String, body: [String: Any] = [:], as: T.Type = T.self) async throws -> T {
        try start()
        guard let endpoint else { throw EngineError(message: "本地引擎尚未就绪") }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = path == "export" ? 3600 : 300
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
            throw EngineError(message: error?["error"] ?? "本地引擎没有完成此次操作")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    func health() async throws -> [String] {
        try start()
        var request = URLRequest(url: endpoint!.appendingPathComponent("health"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        struct Health: Decodable { var missing: [String] }
        return try JSONDecoder().decode(Health.self, from: data).missing
    }

    func get<T:Decodable>(_ path:String,query:[URLQueryItem]=[]) async throws -> T {
        try start()
        var components=URLComponents(url:endpoint!.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty {components.queryItems=query}
        var request=URLRequest(url:components.url!)
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        let (data,response)=try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200 else {throw EngineError(message:"本地引擎请求未完成")}
        let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self,from:data)
    }

    func progress() async throws -> (Int, Int, String) {
        guard let endpoint else { return (0,0,"") }
        var request = URLRequest(url: endpoint.appendingPathComponent("progress"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        struct Progress: Decodable { var done: Int; var total: Int; var name: String }
        let p = try JSONDecoder().decode(Progress.self, from:data)
        return (p.done,p.total,p.name)
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }
}
