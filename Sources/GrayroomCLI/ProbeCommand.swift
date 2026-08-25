import ArgumentParser
import Foundation
import ImageIO
import GrayroomCore

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Print decode metadata for a RAW or standard image file.")

    @Argument(help: "Path to the image file.")
    var input: String

    func run() throws {
        let url = URL(fileURLWithPath: input)
        let metal = try MetalContext()
        let decoder = ImageDecoder(metal: metal)
        let info = try decoder.probe(url: url)

        var out = ""
        out += "file:                 \(info.url.path)\n"
        out += "raw:                  \(info.isRAW ? "yes" : "no")\n"
        if let make = info.cameraMake { out += "make:                 \(make)\n" }
        if let model = info.cameraModel { out += "model:                \(model)\n" }
        if let make = info.lensMake { out += "lensMake:             \(make)\n" }
        if let model = info.lensModel { out += "lensModel:            \(model)\n" }
        out += "nativeSize:           \(Int(info.nativeSize.width)) x \(Int(info.nativeSize.height))\n"
        out += "orientation:          \(info.orientation.rawValue) (\(orientationName(info.orientation)))\n"
        out += "orientedSize:         \(Int(info.orientedSize.width)) x \(Int(info.orientedSize.height))\n"
        out += String(format: "asShotTemperature:    %.1f K\n", info.asShotTemperature)
        out += String(format: "asShotTint:           %.2f\n", info.asShotTint)
        out += "decoderVersion:       \(info.decoderVersion)\n"
        out += "supportedDecoders:    \(info.supportedDecoderVersions.joined(separator: ", "))\n"
        out += "embeddedThumbnail:    \(info.hasEmbeddedThumbnail ? "yes" : "no")\n"
        out += "previewImage:         \(info.hasPreviewImage ? "yes" : "no")\n"
        out += "lensCorrection:       \(info.lensCorrectionSupported ? "supported" : "unsupported")\n"
        out += "highlightRecovery:    "
            + (info.highlightRecoverySupported
                ? (info.highlightRecoveryEnabled ? "enabled" : "supported, off")
                : "unsupported") + "\n"
        out += "contentHeadroom:      " + (info.contentHeadroom > 0
            ? String(format: "%.3f", info.contentHeadroom) : "unknown") + "\n"
        out += "averageLightLevel:    " + (info.contentAverageLightLevel > 0
            ? String(format: "%.4f", info.contentAverageLightLevel) : "unknown") + "\n"
        print(out, terminator: "")
    }

    private func orientationName(_ o: CGImagePropertyOrientation) -> String {
        switch o {
        case .up: return "up"
        case .upMirrored: return "upMirrored"
        case .down: return "down"
        case .downMirrored: return "downMirrored"
        case .leftMirrored: return "leftMirrored"
        case .right: return "right"
        case .rightMirrored: return "rightMirrored"
        case .left: return "left"
        @unknown default: return "unknown"
        }
    }
}
