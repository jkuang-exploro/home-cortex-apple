import SwiftUI
import UIKit

struct BootstrapView: View {
    private let metadata = AppMetadata()

    private var platform: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)

                    Text("Home Cortex")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("bootstrap.title")

                    Text("Apple Client Bootstrap")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Label("App running successfully", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("bootstrap.running")

                VStack(alignment: .leading, spacing: 20) {
                    detail("Platform", value: platform, identifier: "bootstrap.platform")
                    Divider()
                    detail("Epic 3 · Client Interface V1", value: "Not configured yet", identifier: "bootstrap.integration")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                Text(metadata.versionDescription)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bootstrap.version")
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(Color(red: 0.08, green: 0.45, blue: 0.43))
    }

    private func detail(_ title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .accessibilityIdentifier(identifier)
        }
    }
}

#Preview {
    BootstrapView()
}
