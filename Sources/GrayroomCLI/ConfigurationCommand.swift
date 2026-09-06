import ArgumentParser
import GrayroomLibrary

struct ConfigurationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Read or write library configuration.",
        subcommands: [Set.self, Get.self, List.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a value.")
        @Argument var key: String
        @Argument var value: String
        @OptionGroup var libraryOptions: LibraryOptions

        func run() throws {
            let library = try libraryOptions.open()
            try library.setConfiguration(value, forKey: key)
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a value.")
        @Argument var key: String
        @OptionGroup var libraryOptions: LibraryOptions

        func run() throws {
            let library = try libraryOptions.open()
            guard let value = try library.configurationValue(forKey: key) else {
                throw fail("no configuration value for \(key)")
            }
            print(value)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List values.")
        @OptionGroup var libraryOptions: LibraryOptions

        func run() throws {
            let library = try libraryOptions.open()
            for (key, value) in try library.configuration().sorted(by: { $0.key < $1.key }) {
                print("\(key)=\(value)")
            }
        }
    }
}
