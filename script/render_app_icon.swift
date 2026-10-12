import AppKit
import CoreGraphics

// Code-native Photon mark, using the same seven circles and Velocity palette
// as the workspace header. This writes only generated build assets.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift render_app_icon.swift <iconset directory>")
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
            let context = CGContext(data: bitmap.bitmapData, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Could not create icon bitmap")
        }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 12 / 255, green: 12 / 255, blue: 16 / 255, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                               cornerWidth: 196, cornerHeight: 196, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(red: 139 / 255, green: 92 / 255, blue: 246 / 255, alpha: 1))
        let positions = [(0.0, 0.0)] + (0..<6).map { index in
            let angle = Double(index) * .pi / 3
            return (220 * cos(angle), 220 * sin(angle))
        }
        for (x, y) in positions {
            context.fillEllipse(in: CGRect(x: 512 + x - 82, y: 512 + y - 82, width: 164, height: 164))
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode icon")
        }
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
