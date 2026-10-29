import Foundation
import Testing
@testable import PhotoEdit

@Suite struct EnginePathsTests {
    @Test func packagedEngineUsesWritableUserDirectoryAndDevelopmentRootStillWorks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = base.appendingPathComponent("Resources")
        let home = base.appendingPathComponent("home")
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("engine"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data().write(to: resources.appendingPathComponent("engine/service.py"))

        let bundled = EnginePaths.resolve(explicitRoot: nil, resourceRoot: resources, projectRoot: project.path, home: home)
        #expect(bundled.script == resources.appendingPathComponent("engine/service.py"))
        #expect(bundled.python == resources.appendingPathComponent("python/bin/python3"))
        #expect(bundled.root == home.appendingPathComponent("Library/Application Support/SuiTone", isDirectory: true))

        let explicit = EnginePaths.resolve(explicitRoot: project, resourceRoot: resources, projectRoot: nil, home: home)
        #expect(explicit.root == project)
        #expect(explicit.script == project.appendingPathComponent("engine/service.py"))
        #expect(explicit.python == home.appendingPathComponent(".cache/photo-edit/venv/bin/python"))

        let development = EnginePaths.resolve(explicitRoot: nil, resourceRoot: nil, projectRoot: project.path, home: home)
        #expect(development.root == project)
    }
}
