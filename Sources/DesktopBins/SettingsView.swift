import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Open Desktop Bins at login", isOn: $settings.launchAtLogin)
                .font(.system(size: 13, weight: .semibold))

            Divider()

            Toggle("Snap icons to a grid inside bins", isOn: $settings.snapEnabled)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                spacingSlider(
                    label: "Horizontal spacing",
                    value: $settings.gridCellWidth
                )
                spacingSlider(
                    label: "Vertical spacing",
                    value: $settings.gridCellHeight
                )
                Text("Smaller values pack icons closer together. Match this to your desktop icon size — around 112 pt suits Finder’s default grid.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Pack icons together, without gaps", isOn: $settings.packIcons)
                Text(settings.packIcons
                     ? "Icons refill from the top-left of the bin in order, leaving no empty cells."
                     : "Icons stay in whichever cell you drop them near, so gaps between them are preserved.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Reset to Defaults") { settings.resetToDefaults() }
                Spacer()
                Text("Desktop Bins \(AppInfo.displayVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420, height: 420)
    }

    private func spacingSlider(label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: 72...200, step: 4)
                .disabled(!settings.snapEnabled)
        }
    }
}
