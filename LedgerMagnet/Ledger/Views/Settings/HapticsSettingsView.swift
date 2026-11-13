import SwiftUI

/// 設定 → 觸覺回饋：總開關、強度、各項開關（打開時會試震一下）
struct HapticsSettingsView: View {
    @AppStorage(Haptics.enabledKey) private var enabled = true
    @AppStorage(Haptics.strengthKey) private var strength = Haptics.defaultStrength

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    SettingsRowLabel("觸覺回饋", "water.waves")
                }
                .onChange(of: enabled) { _, on in
                    if on { Haptics.shared.sample(nil) }
                }
            }

            if enabled {
                Section {
                    VStack(spacing: 10) {
                        HStack {
                            Text("強度")
                            Spacer()
                            Text(strengthLabel).foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "iphone.gen3").font(.footnote).foregroundStyle(.secondary)
                            Slider(value: $strength, in: Haptics.strengthRange, step: 0.1,
                                   onEditingChanged: sliderChanged)
                            Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Button("試震") { Haptics.shared.sample(nil) }
                    if strength != Haptics.defaultStrength {
                        Button("回復預設強度") {
                            strength = Haptics.defaultStrength
                            Haptics.shared.sample(nil)
                        }
                    }
                } footer: {
                    Text("放開滑桿會試震一下。")
                }

                Section {
                    ForEach(HapticKind.allCases) { kind in
                        HapticKindToggle(kind: kind)
                    }
                } header: {
                    SettingsHeader("各項震動")
                }
            }
        }
        .settingsStyle()
        .navigationTitle("觸覺回饋")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: enabled)
    }

    private func sliderChanged(_ editing: Bool) {
        if !editing { Haptics.shared.sample(nil) }
    }

    private var strengthLabel: String {
        "\(Int((strength / Haptics.defaultStrength * 100).rounded()))%"
    }
}

private struct HapticKindToggle: View {
    var kind: HapticKind
    @AppStorage private var on: Bool

    init(kind: HapticKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: true, kind.key)
    }

    var body: some View {
        Toggle(isOn: $on) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: kind.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.label)
                    Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
        }
        .onChange(of: on) { _, isOn in
            if isOn { Haptics.shared.sample(kind) }
        }
    }
}
