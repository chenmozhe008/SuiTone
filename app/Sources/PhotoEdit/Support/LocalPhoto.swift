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
    /// 缩略图铺满格子并裁掉多余部分，避免比例不符时露出底色；主画布仍完整显示。
    var fill = false
    var body: some View {
        if let image = ImageCache.load(path) {
            if fill {
                Color.clear.overlay(Image(nsImage: image).resizable().interpolation(.high).scaledToFill()).clipped()
            } else {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }
}
