import ArgumentParser
import Foundation

@main
struct Grayroom: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grayroom",
        abstract: "Headless B&W RAW developer.",
        version: "0.1.0 (M1)",
        subcommands: [Probe.self, Render.self],
        defaultSubcommand: nil)
}

func fail(_ message: String) -> ValidationError {
    ValidationError(message)
}

func standardError(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}
