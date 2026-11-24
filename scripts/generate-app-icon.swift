import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4 else {
    fputs("usage: generate-app-icon.swift <source-directory> <iconset-directory> <light|dark>\n", stderr)
    exit(2)
}

let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let appearance = CommandLine.arguments[3]

guard appearance == "light" || appearance == "dark" else {
    fputs("appearance must be light or dark\n", stderr)
    exit(2)
}

let regularURL = sourceDirectory.appendingPathComponent("nenring-icon-\(appearance).svg")
let smallURL = sourceDirectory.appendingPathComponent("nenring-icon-\(appearance)-small.svg")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let outputs: [(pixels: Int, filename: String, small: Bool)] = [
    (16, "icon_16x16.png", true),
    (32, "icon_16x16@2x.png", true),
    (32, "icon_32x32.png", true),
    (64, "icon_32x32@2x.png", true),
    (128, "icon_128x128.png", true),
    (256, "icon_128x128@2x.png", true),
    (256, "icon_256x256.png", false),
    (512, "icon_256x256@2x.png", false),
    (512, "icon_512x512.png", false),
    (1024, "icon_512x512@2x.png", false)
]

for output in outputs {
    let sourceURL = output.small ? smallURL : regularURL
    let image = try renderSVG(at: sourceURL, pixelSize: output.pixels)
    let destinationURL = iconsetURL.appendingPathComponent(output.filename)

    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconGenerationError.couldNotCreateDestination(destinationURL.path)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconGenerationError.couldNotWrite(destinationURL.path)
    }
}

func renderSVG(at url: URL, pixelSize: Int) throws -> CGImage {
    guard let source = NSImage(contentsOf: url) else {
        throw IconGenerationError.couldNotLoad(url.path)
    }

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw IconGenerationError.couldNotCreateBitmap(pixelSize)
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconGenerationError.couldNotCreateGraphicsContext
    }

    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()

    source.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: nil
    )
    graphicsContext.flushGraphics()

    guard let cgImage = bitmap.cgImage else {
        throw IconGenerationError.couldNotCreateCGImage
    }
    return cgImage
}

enum IconGenerationError: Error, CustomStringConvertible {
    case couldNotLoad(String)
    case couldNotCreateBitmap(Int)
    case couldNotCreateGraphicsContext
    case couldNotCreateCGImage
    case couldNotCreateDestination(String)
    case couldNotWrite(String)

    var description: String {
        switch self {
        case .couldNotLoad(let path): return "could not load SVG: \(path)"
        case .couldNotCreateBitmap(let size): return "could not create \(size)x\(size) bitmap"
        case .couldNotCreateGraphicsContext: return "could not create graphics context"
        case .couldNotCreateCGImage: return "could not create CGImage"
        case .couldNotCreateDestination(let path): return "could not create PNG destination: \(path)"
        case .couldNotWrite(let path): return "could not write PNG: \(path)"
        }
    }
}
