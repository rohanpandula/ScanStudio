import ScanStudioKit
import SwiftUI

struct HardwareSettingsView: View {
    @Bindable var model: SessionModel

    var body: some View {
        Form {
            Section("Scanners") {
                Toggle("Allow unverified scanners", isOn: $model.allowUnverifiedHardware)
                Text("Recognized hardware without verified support can be connected when this is enabled. Unverified connections and receipts are marked clearly; motion safety checks are unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
