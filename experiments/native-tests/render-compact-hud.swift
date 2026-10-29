import AppKit
import SwiftUI

@main
struct RenderCompactHUD {
    @MainActor static func main() throws {
        let model = HUDModel()
        model.phase = .listening(handsFree: false)
        model.preview = "A compact preview shows the latest words without covering the application you are using."
        let renderer = ImageRenderer(content: HUDView(model: model))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
