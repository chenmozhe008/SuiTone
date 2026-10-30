import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 系统主体抠图（Vision 前景分割，照片 App 长按抠图同款）：点哪个主体抠哪个，输出透明 PNG。
/// 不下载模型、不联网；找不到主体或点在背景上时如实报错。
enum SubjectCutout {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// point 为 0–1 比例坐标，原点在左上。成功时把透明 PNG 写到 output，返回主体占画面的比例。
    @discardableResult
    static func cutout(image url: URL, point: CGPoint, output: URL) throws -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "无法读取照片")
        }
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure(message: "没有找到可以抠出的主体，照片里可能没有清晰的人物或物体")
        }
        let label = instance(at: point, in: observation.instanceMask)
        guard label != 0 else {
            throw Failure(message: "点到的是背景，请点在人物或物体上")
        }
        let mask = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler)
        let (pixels, coverage) = try composite(image, mask: mask)
        try write(pixels, width: image.width, height: image.height, to: output)
        return coverage
    }

    /// 实例图是低分辨率的标签图：0 为背景，1… 为各个主体。
    private static func instance(at point: CGPoint, in labels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let width = CVPixelBufferGetWidth(labels), height = CVPixelBufferGetHeight(labels)
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return 0 }
        let row = CVPixelBufferGetBytesPerRow(labels)
        let x = min(max(Int(point.x * Double(width)), 0), width - 1)
        let y = min(max(Int(point.y * Double(height)), 0), height - 1)
        return Int(base.load(fromByteOffset: y * row + x, as: UInt8.self))
    }

    /// 把照片画进 RGBA 缓冲，按遮罩（0–1 浮点，与照片同尺寸）设透明度，输出预乘 alpha 的像素。
    private static func composite(_ image: CGImage, mask: CVPixelBuffer) throws -> ([UInt8], Double) {
        let width = image.width, height = image.height
        guard CVPixelBufferGetWidth(mask) == width, CVPixelBufferGetHeight(mask) == height else {
            throw Failure(message: "抠图遮罩尺寸与照片不一致")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure(message: "无法生成抠图")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { throw Failure(message: "无法读取抠图遮罩") }
        let row = CVPixelBufferGetBytesPerRow(mask)
        var covered = 0
        for y in 0..<height {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let alpha = min(max(line[x], 0), 1)
                let i = (y * width + x) * 4
                if alpha >= 0.5 { covered += 1 }
                pixels[i] = UInt8(Float(pixels[i]) * alpha + 0.5)
                pixels[i + 1] = UInt8(Float(pixels[i + 1]) * alpha + 0.5)
                pixels[i + 2] = UInt8(Float(pixels[i + 2]) * alpha + 0.5)
                pixels[i + 3] = UInt8(alpha * 255 + 0.5)
            }
        }
        return (pixels, Double(covered) / Double(width * height))
    }

    private static func write(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(message: "无法写入 PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "无法写入 PNG") }
    }
}
