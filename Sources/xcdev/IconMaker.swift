import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Regenerates every icon the app ships from the artwork in `Graphics/`.
///
/// - The app icon is an Icon Composer document. It's copied as is: it already is the design,
///   and macOS draws it with its own geometry.
/// - The menu bar mark is rendered from the same artwork, hat and sabres, as a template image
///   (see `makeMenuBarMark`).
/// - The `.icns` for a DMG's volume icon is compiled from the app icon by `actool`.
///
/// Needs `rsvg-convert` to render the SVG: `brew install librsvg`.
struct IconMaker {
    let project: Project

    let iconSource = "Graphics/XCommanderAppIconDefault.icon"
    let markSource = "Graphics/XCommander-black.svg"
    let iconDestination = "Sources/Companion/XCommanderAppIcon.icon"
    let markDestination = "Sources/Companion/Assets.xcassets/MenuBarMark.imageset"

    func make() throws {
        guard isInstalled("rsvg-convert") else {
            throw Message("rsvg-convert is needed to render the SVG: brew install librsvg")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "xcdev-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        print("App icon: copying \(iconSource)")
        let destination = project.path(iconDestination)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: project.path(iconSource), to: destination)

        print("Menu bar mark: rendering \(markSource)")
        try makeMenuBarMark(work: work)

        print("DMG icon: compiling Design/XCommander.icns")
        try shell("xcrun", "actool", destination.path, "--compile", work.path,
                  "--platform", "macosx", "--minimum-deployment-target", "14.0",
                  "--app-icon", "XCommanderAppIcon",
                  "--output-partial-info-plist", work.appending(path: "partial.plist").path,
                  "--output-format", "human-readable-text", capture: true)
        let icns = project.path("Design/XCommander.icns")
        try? FileManager.default.removeItem(at: icns)
        try FileManager.default.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: work.appending(path: "XCommanderAppIcon.icns"), to: icns)
        print("Done.")
    }

    /// The menu bar mark is a *template image*: macOS ignores its colours and uses its alpha as a
    /// mask, painting it black on a light menu bar and white on a dark one. Three steps get it
    /// from the artwork:
    ///
    /// 1. **Ink is what's opaque and dark.** The ⌘ on the hat's crown is painted on top in light
    ///    grey, so it's opaque. Using alpha alone would give a solid hat with no ⌘. Multiplying
    ///    alpha by darkness turns the light details into holes the menu bar can show through.
    /// 2. **Fill the trim.** The thin white line along the hat's edge is lovely at 1024 pixels
    ///    and just makes the hat look faint at menu bar size. It's one long hole, so every hole
    ///    wider than half the artwork is filled. The ⌘ and the lines down the blades are small and
    ///    stay cut out.
    /// 3. **Size it for the menu bar.** The artwork fills the usual 18 pt height, and the canvas
    ///    is as wide as its proportions need (about 21 pt), rounded down so it never overflows.
    private func makeMenuBarMark(work: URL) throws {
        let rendered = work.appending(path: "hat.png")
        try shell("rsvg-convert", "-w", "2048", "-h", "2048", "-f", "png",
                  "-o", rendered.path, project.path(markSource).path)

        var mask = try Mask(inkFrom: rendered)
        mask.cropToInk()
        mask.fillHoles(widerThan: mask.width / 2)

        let canvasHeight = 18
        let canvasWidth = Int(Double(canvasHeight) * Double(mask.width) / Double(mask.height))
        let markset = project.path(markDestination)
        for scale in [1, 2] {
            let name = scale == 1 ? "mark.png" : "mark@\(scale)x.png"
            let png = try mask.templatePNG(width: canvasWidth * scale, canvasHeight: canvasHeight * scale)
            try png.write(to: markset.appending(path: name))
            print("  \(name)  \(canvasWidth * scale)×\(canvasHeight * scale)")
        }

        let contents: [String: Any] = [
            "images": [
                ["idiom": "mac", "scale": "1x", "filename": "mark.png"],
                ["idiom": "mac", "scale": "2x", "filename": "mark@2x.png"],
            ],
            "info": ["author": "xcode", "version": 1],
            "properties": ["template-rendering-intent": "template"],
        ]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: markset.appending(path: "Contents.json"))
    }
}

/// A grayscale image where each pixel says how much ink there is (0 = none, 255 = full).
struct Mask {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    /// Ink = alpha × darkness, read from a rendered PNG.
    init(inkFrom url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Message("Couldn't read \(url.path)")
        }
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Message("Couldn't decode \(url.path)") }

        var ink = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let alpha = Int(rgba[i * 4 + 3])
            guard alpha > 0 else { continue }
            // Undo premultiplication to get the real colour, then its brightness (Rec. 601).
            let r = Int(rgba[i * 4]) * 255 / alpha
            let g = Int(rgba[i * 4 + 1]) * 255 / alpha
            let b = Int(rgba[i * 4 + 2]) * 255 / alpha
            let brightness = (r * 299 + g * 587 + b * 114) / 1000
            ink[i] = UInt8(alpha * (255 - min(brightness, 255)) / 255)
        }
        pixels = ink
    }

    mutating func cropToInk() {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return }
        let newWidth = maxX - minX + 1, newHeight = maxY - minY + 1
        var cropped = [UInt8](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                cropped[y * newWidth + x] = pixels[(y + minY) * width + (x + minX)]
            }
        }
        width = newWidth; height = newHeight; pixels = cropped
    }

    /// Fills every enclosed hole wider than `limit` pixels.
    ///
    /// "Enclosed" means not reachable from the edge of the image without crossing ink. Holes
    /// are found by flood filling: first everything reachable from outside, then each remaining
    /// gap one at a time.
    mutating func fillHoles(widerThan limit: Int) {
        let solid = pixels.map { $0 > 127 }
        var outside = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        for x in 0..<width { queue.append(x); queue.append((height - 1) * width + x) }
        for y in 0..<height { queue.append(y * width); queue.append(y * width + width - 1) }
        queue = queue.filter { !solid[$0] }
        queue.forEach { outside[$0] = true }
        flood(&queue, marking: &outside, through: { !solid[$0] })

        var visited = outside
        for start in 0..<(width * height) where !solid[start] && !visited[start] {
            var hole: [Int] = []
            var frontier = [start]
            visited[start] = true
            while let index = frontier.popLast() {
                hole.append(index)
                for next in neighbours(of: index) where !solid[next] && !visited[next] {
                    visited[next] = true
                    frontier.append(next)
                }
            }
            let xs = hole.map { $0 % width }
            if xs.max()! - xs.min()! + 1 > limit {
                for index in hole { pixels[index] = 255 }
            }
        }
    }

    private func flood(_ queue: inout [Int], marking marked: inout [Bool], through passable: (Int) -> Bool) {
        while let index = queue.popLast() {
            for next in neighbours(of: index) where !marked[next] && passable(next) {
                marked[next] = true
                queue.append(next)
            }
        }
    }

    private func neighbours(of index: Int) -> [Int] {
        let x = index % width, y = index / width
        var result: [Int] = []
        if x > 0 { result.append(index - 1) }
        if x < width - 1 { result.append(index + 1) }
        if y > 0 { result.append(index - width) }
        if y < height - 1 { result.append(index + width) }
        return result
    }

    /// Scales the ink to `width`, centres it vertically on a `width × canvasHeight` canvas, and
    /// returns it as a PNG of black pixels whose alpha is the ink.
    func templatePNG(width targetWidth: Int, canvasHeight: Int) throws -> Data {
        let targetHeight = max(1, Int((Double(height) * Double(targetWidth) / Double(width)).rounded()))

        // Scale the mask down with a Lanczos filter (vImage's high-quality resampling). It
        // keeps the ⌘ crisp; Core Graphics' interpolation blurs them at this
        // size.
        var scaledPixels = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        var sourcePixels = pixels
        let error = sourcePixels.withUnsafeMutableBytes { sourceBytes in
            scaledPixels.withUnsafeMutableBytes { scaledBytes in
                var source = vImage_Buffer(data: sourceBytes.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width)
                var scaledBuffer = vImage_Buffer(data: scaledBytes.baseAddress,
                                                 height: vImagePixelCount(targetHeight),
                                                 width: vImagePixelCount(targetWidth), rowBytes: targetWidth)
                return vImageScale_Planar8(&source, &scaledBuffer, nil,
                                           vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw Message("Couldn't scale the menu bar mark (\(error))") }
        let scaled = scaledPixels

        // Black pixels, alpha from the mask. The context's rows run top to bottom in memory.
        var rgba = [UInt8](repeating: 0, count: targetWidth * canvasHeight * 4)
        let top = (canvasHeight - targetHeight) / 2
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                rgba[((y + top) * targetWidth + x) * 4 + 3] = scaled[y * targetWidth + x]
            }
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let canvasProvider = CGDataProvider(data: Data(rgba) as CFData),
              let canvas = CGImage(width: targetWidth, height: canvasHeight, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: targetWidth * 4, space: srgb,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: canvasProvider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent)
        else { throw Message("Couldn't draw the menu bar mark") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw Message("Couldn't encode the menu bar mark") }
        CGImageDestinationAddImage(destination, canvas, nil)
        guard CGImageDestinationFinalize(destination) else { throw Message("Couldn't encode the menu bar mark") }
        return output as Data
    }
}
