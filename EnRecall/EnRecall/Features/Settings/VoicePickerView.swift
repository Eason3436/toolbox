import SwiftUI
import AVFoundation

/// 設定 › 發音 › 聲音：列出手機上 App 看得到的英文聲音，點一下選用並試聽
struct VoicePickerView: View {
    @AppStorage(SettingsKey.speechVoice) private var selected = ""
    @AppStorage(SettingsKey.speechRate) private var rate = SpeechService.defaultRate

    @State private var voices: [AVSpeechSynthesisVoice] = []

    static let sample = "Please fill the bottle with clean water before the trip."

    private struct VoiceGroup {
        let title: String
        let voices: [AVSpeechSynthesisVoice]
    }

    private var groups: [VoiceGroup] {
        let order: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]
        var result: [VoiceGroup] = []
        for quality in order {
            let matching: [AVSpeechSynthesisVoice] = voices.filter { $0.quality == quality }
            if let first = matching.first {
                result.append(VoiceGroup(title: first.qualityTitle, voices: matching))
            }
        }
        return result
    }

    private var hasBetterVoices: Bool {
        voices.contains { $0.quality != .default }
    }

    var body: some View {
        List {
            Section {
                row(
                    title: "自動",
                    subtitle: SpeechService.automaticVoice.map { "\($0.name)・\($0.qualityTitle)" },
                    isSelected: selected.isEmpty || !voices.contains { $0.identifier == selected }
                ) {
                    selected = ""
                    SpeechService.shared.speak(Self.sample, voice: SpeechService.automaticVoice, rate: rate)
                }
            } footer: {
                Text("自動會挑品質最好的美式英文聲音")
            }
            .listRowBackground(Color.er.surface)

            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.voices, id: \.identifier) { voice in
                        row(title: voice.name, subtitle: voice.languageTitle, isSelected: selected == voice.identifier) {
                            selected = voice.identifier
                            SpeechService.shared.speak(Self.sample, voice: voice, rate: rate)
                        }
                    }
                }
                .listRowBackground(Color.er.surface)
            }

            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !hasBetterVoices {
                        Text("App 目前看不到任何增強或高音質的聲音")
                            .foregroundStyle(Color.er.danger)
                    }
                    Text("要更自然的聲音：到「設定 › 輔助使用 › 朗讀內容 › 聲音 › 英文」下載名字後面有「增強音質」或「高音質」的聲音，再回來這裡選。Siri 的聲音 Apple 不開放給 App 使用。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .erPageBackground()
        .navigationTitle("聲音")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            reload()
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func reload() {
        voices = SpeechService.englishVoices()
    }

    private func row(title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.er.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.er.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.er.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("選用並試聽")
    }
}

/// 設定頁的「發音」區：聲音、語速、試聽
struct SpeechSettingsSection: View {
    @AppStorage(SettingsKey.speechVoice) private var selected = ""
    @AppStorage(SettingsKey.speechRate) private var rate = SpeechService.defaultRate

    private var voiceTitle: String {
        if !selected.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: selected) {
            return voice.name
        }
        return "自動"
    }

    var body: some View {
        Section {
            NavigationLink {
                VoicePickerView()
            } label: {
                LabeledContent("聲音", value: voiceTitle)
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("語速") {
                    Text(rate.formatted(.number.precision(.fractionLength(1))) + "×")
                        .monospacedDigit()
                }
                Slider(value: $rate, in: SpeechService.rateRange, step: 0.1) {
                    Text("語速")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                        .foregroundStyle(Color.er.textSecondary)
                } maximumValueLabel: {
                    Image(systemName: "hare")
                        .foregroundStyle(Color.er.textSecondary)
                } onEditingChanged: { editing in
                    if !editing { SpeechService.shared.speak(VoicePickerView.sample) }
                }
                .accessibilityValue(rate.formatted(.number.precision(.fractionLength(1))) + " 倍")
            }
            .sensoryFeedback(.selection, trigger: rate)
            Button {
                SpeechService.shared.speak(VoicePickerView.sample)
            } label: {
                Label("試聽", systemImage: "speaker.wave.2")
            }
        } header: {
            Text("發音")
        } footer: {
            Text("單字和例句都會用這個聲音和語速")
        }
        .listRowBackground(Color.er.surface)
    }
}

#Preview("淺色") {
    NavigationStack {
        Form {
            SpeechSettingsSection()
        }
        .scrollContentBackground(.hidden)
        .erPageBackground()
    }
}

#Preview("深色") {
    NavigationStack {
        VoicePickerView()
    }
    .preferredColorScheme(.dark)
}
