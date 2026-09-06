import AppKit
import Observation
import SwiftUI

@Observable
final class OriginalStorageSetupModel {
    var endpoint = ""
    var region = ""
    var bucket = ""
    var prefix = "originals"
    var cacheDirectory: String = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grayroom/Originals", isDirectory: true).path
    }()
    var accessKeyID = ""
    var secretAccessKey = ""
    var sessionToken = ""
    var errorMessage: String?
}

struct OriginalStorageSetupSheet: View {
    @Bindable var setup: OriginalStorageSetupModel
    let chooseCacheDirectory: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Original Storage").font(.headline)
            Text("Grayroom needs an S3-compatible bucket and a local cache before it can use the library.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                field("Endpoint", text: $setup.endpoint, probe: "storage-endpoint")
                field("Region", text: $setup.region, probe: "storage-region")
                field("Bucket", text: $setup.bucket, probe: "storage-bucket")
                field("Object prefix", text: $setup.prefix, probe: "storage-prefix")
                GridRow {
                    Text("Cache directory")
                    HStack {
                        TextField("/path/to/cache", text: $setup.cacheDirectory)
                            .controlProbe("storage-cache-directory")
                        Button("Choose…", action: chooseCacheDirectory)
                            .controlProbe("storage-cache-choose")
                    }
                }
                field("Access key ID", text: $setup.accessKeyID, probe: "storage-access-key")
                GridRow {
                    Text("Secret access key")
                    SecureField("Required", text: $setup.secretAccessKey)
                        .controlProbe("storage-secret-key")
                }
                GridRow {
                    Text("Session token")
                    SecureField("Optional", text: $setup.sessionToken)
                        .controlProbe("storage-session-token")
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("Credentials are stored in your macOS Keychain, not in the library database.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let error = setup.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .controlProbe("storage-error")
            }
            HStack {
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .controlProbe("storage-save")
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }

    private func field(_ label: String, text: Binding<String>, probe: String) -> some View {
        GridRow {
            Text(label)
            TextField(label, text: text).controlProbe(probe)
        }
    }
}
