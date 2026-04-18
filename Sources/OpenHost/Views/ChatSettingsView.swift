import SwiftUI

struct ChatSettingsView: View {
    let conversationID: UUID
    @StateObject private var store = ChatStore.shared
    @EnvironmentObject var registry: ModelRegistry

    var body: some View {
        if let convo = store.binding(for: conversationID) {
            let binding = Binding<ChatSettings>(
                get: { convo.settings },
                set: { newVal in
                    var updated = convo
                    updated.settings = newVal
                    store.update(updated)
                }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Settings").font(.title3.weight(.semibold))
                        .padding(.top, 18)

                    section("System prompt") {
                        TextEditor(text: Binding(
                            get: { binding.wrappedValue.systemPrompt },
                            set: { var s = binding.wrappedValue; s.systemPrompt = $0; binding.wrappedValue = s }
                        ))
                        .font(.system(size: 12, design: .default))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80, maxHeight: 160)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }

                    section("Sampling") {
                        slider("Temperature", value: Binding(
                            get: { binding.wrappedValue.temperature },
                            set: { var s = binding.wrappedValue; s.temperature = $0; binding.wrappedValue = s }
                        ), range: 0...2, step: 0.05, format: "%.2f")

                        slider("Top-P", value: Binding(
                            get: { binding.wrappedValue.topP },
                            set: { var s = binding.wrappedValue; s.topP = $0; binding.wrappedValue = s }
                        ), range: 0...1, step: 0.01, format: "%.2f")

                        intSlider("Top-K", value: Binding(
                            get: { binding.wrappedValue.topK },
                            set: { var s = binding.wrappedValue; s.topK = $0; binding.wrappedValue = s }
                        ), range: 0...100)

                        slider("Min-P", value: Binding(
                            get: { binding.wrappedValue.minP },
                            set: { var s = binding.wrappedValue; s.minP = $0; binding.wrappedValue = s }
                        ), range: 0...0.5, step: 0.01, format: "%.2f")

                        slider("Presence penalty", value: Binding(
                            get: { binding.wrappedValue.presencePenalty },
                            set: { var s = binding.wrappedValue; s.presencePenalty = $0; binding.wrappedValue = s }
                        ), range: 0...2, step: 0.05, format: "%.2f")
                    }

                    section("Limits") {
                        intSlider("Max output tokens", value: Binding(
                            get: { binding.wrappedValue.maxTokens },
                            set: { var s = binding.wrappedValue; s.maxTokens = $0; binding.wrappedValue = s }
                        ), range: 64...8192, step: 64)
                    }

                    section("Presets") {
                        HStack {
                            Button("Default") {
                                binding.wrappedValue = ChatSettings()
                            }
                            Button("llama.cpp tuned") {
                                var s = ChatSettings.llamaCppRecommended
                                s.systemPrompt = binding.wrappedValue.systemPrompt
                                binding.wrappedValue = s
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    @ViewBuilder
    private func intSlider(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}
