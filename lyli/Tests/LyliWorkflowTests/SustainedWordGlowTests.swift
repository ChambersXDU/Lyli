import AppKit
import SwiftUI
import LyliCore
@testable import lyli

@MainActor
struct SustainedWordGlowTests {
    private let word = SyncedLyricWord(text: "光", startMs: 1_000, durationMs: 2_000)

    func testPauseReducedMotionAndLineFallbackSuppressGlow() {
        func intensity(playing: Bool = true, reduced: Bool = false, count: Int = 2) -> Double {
            SustainedWordGlow.intensity(for: word, atMs: 2_000, wordCount: count,
                                       isPlaying: playing, reduceMotion: reduced)
        }
        expectEqual(intensity() > 0, true)
        expectEqual(intensity(playing: false), 0.0)
        expectEqual(intensity(reduced: true), 0.0)
        expectEqual(intensity(count: 0), 0.0)
        expectEqual(intensity(count: 1) > 0, true)
    }

    private func image(intensity: Double, color: Color = .white) throws -> CGImage {
        let renderer = ImageRenderer(content:
            Text("光").font(.system(size: 40, weight: .bold)).foregroundStyle(color)
                .modifier(SustainedWordGlow(color: color, intensity: intensity)).padding(12))
        renderer.scale = 2
        return try require(renderer.cgImage)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testGlowRendersOutsideGlyphWithoutChangingLayout() throws {
        for color in [Color.white, .black, .cyan] {
            let normal = try image(intensity: 0, color: color)
            let glowing = try image(intensity: 0.6, color: color)
            expectEqual(normal.width, glowing.width)
            expectEqual(normal.height, glowing.height)
            let a = try rgba(normal)
            let b = try rgba(glowing)
            let pixels = stride(from: 0, to: a.count, by: 4)
            let halo = pixels.filter { a[$0 + 3] == 0 && b[$0 + 3] > 5 }.count
            expectEqual(halo > 20, true)
            let solid = pixels.filter { a[$0 + 3] == 255 }
            expectEqual(solid.count > 20, true)
            expectEqual(solid.allSatisfy { a[$0...$0 + 3] == b[$0...$0 + 3] }, true)
        }
    }

    private func scene(intensity: Double, progress: Double = 0.5) -> some View {
        HStack(spacing: 0) {
            ForEach(Array("让声音慢慢亮起").indices, id: \.self) { index in
                let text = String(Array("让声音慢慢亮起")[index])
                let style = WordKaraokeGradient.gradient(fg: .white, left: index == 5 ? progress - 0.08 : 1.1,
                                                         right: index == 5 ? progress + 0.08 : 1.2)
                Text(text).foregroundStyle(style)
                    .modifier(SustainedWordGlow(color: .white, intensity: index == 5 ? intensity : 0))
            }
        }
        .font(.system(size: 40, weight: .bold)).padding(20)
        .frame(width: 400, height: 120).background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }

    func runRenderProbe() throws {
        func render(_ intensity: Double, progress: Double = 0.5) throws -> CGImage {
            let renderer = ImageRenderer(content: scene(intensity: intensity, progress: progress))
            renderer.scale = 2
            return try require(renderer.cgImage)
        }
        for _ in 0..<10 { _ = try render(0); _ = try render(0.55) }
        var normal: [Double] = [], glow: [Double] = []
        for frame in 0..<60 {
            let progress = Double(frame + 1) / 61
            let intensity = KaraokeFill.sustainGlowIntensity(for: word, atMs: 1_000 + Int(progress * 2_000))
            for value in [0.0, intensity] {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try render(value, progress: progress)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if value == 0 { normal.append(elapsed) } else { glow.append(elapsed) }
            }
        }
        let a = normal.sorted()[normal.count / 2], b = glow.sorted()[glow.count / 2]
        print(String(format: "GLOW RENDER: 7 glyphs, 40pt, 2x; baseline median %.3f ms, glow median %.3f ms, delta %.3f ms; 30fps budget 33.333 ms", a, b, b - a))
        let comparison = ImageRenderer(content: HStack(spacing: 2) {
            VStack(spacing: 0) { Text("普通逐字高亮").font(.system(size: 16)).foregroundStyle(.white); scene(intensity: 0) }
            VStack(spacing: 0) { Text("长音辉光").font(.system(size: 16)).foregroundStyle(.white); scene(intensity: 0.55) }
        }.padding(16).background(Color(red: 0.09, green: 0.10, blue: 0.12)))
        comparison.scale = 2
        let png = try require(NSBitmapImageRep(cgImage: try require(comparison.cgImage)).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/lyli-long-note-glow-comparison.png"))
    }
}
