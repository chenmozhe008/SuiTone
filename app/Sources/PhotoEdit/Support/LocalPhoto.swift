import AppKit
import SwiftUI

@MainActor
private enum ImageCache {
    static let values: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    static func load(_ path: String) -> NSImage? {
        if let value = values.object(forKey: path as NSString) { return value }
        guard let value = NSImage(contentsOfFile: path) else { return nil }
        values.setObject(value, forKey: path as NSString, cost: Int(value.size.width*value.size.height*4))
        return value
    }
}

struct LocalPhoto: View {
    let path: String
    var body: some View {
        if let image = ImageCache.load(path) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}
