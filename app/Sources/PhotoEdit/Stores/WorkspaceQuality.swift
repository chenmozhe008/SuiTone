import Foundation

extension WorkspaceStore {
    func applyQuality(denoise: Bool? = nil, scale: Int? = nil) {
        guard !controlsBlocked, scale == nil || [1, 2, 4].contains(scale!) else { return }
        let items = targets.filter { (denoise != nil && $0.quality.denoise != denoise!) || (scale != nil && $0.quality.scale != scale!) }
        runPhotoOperation(.quality(denoise: denoise, scale: scale), items: items, label: "调整画质")
    }
}
