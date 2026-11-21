import SwiftUI

struct ContentView: View {
    @StateObject private var reader = SignReader()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                cameraCard
                Picker("Signs", selection: $reader.signSet) {
                    ForEach(SignSet.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                topPredictions
                textPanel
                suggestionRow
                controls
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("ASL Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { reader.flipCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                    }
                    .accessibilityLabel("Switch camera")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(reader: reader) }
        }
        .onAppear { reader.startCamera() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { reader.startCamera() } else if phase == .background { reader.stopCamera() }
        }
    }

    // MARK: Camera with live prediction overlay

    private var cameraCard: some View {
        CameraPreview(session: reader.camera.session)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Text(String(format: "%.1f ms · %.0f fps", reader.latencyMs, reader.fps))
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
                    .opacity(reader.modelReady ? 1 : 0)
            }
            .overlay {
                // the model reads the central 90% of the square (training eval crop)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .frame(width: geo.size.width * SignClassifier.cropFraction,
                               height: geo.size.height * SignClassifier.cropFraction)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { liveSign }
            .overlay {
                if !reader.modelReady || reader.status.hasPrefix("Camera") || reader.status.hasPrefix("No ") {
                    Text(reader.status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var liveSign: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: reader.holdProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: reader.holdProgress)
                Text(displayName(reader.currentLabel))
                    .font(.system(size: reader.currentLabel.count > 1 ? 15 : 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .padding(6)
            }
            .frame(width: 66, height: 66)

            VStack(alignment: .leading, spacing: 6) {
                Text(reader.isReading ? "Hold the sign inside the frame" : "Paused")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: Double(reader.confidence))
                    .tint(reader.confidence >= reader.threshold ? .green : .orange)
                Text(String(format: "Confidence %.0f%%", reader.confidence * 100))
                    .font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .padding(10)
        .opacity(reader.modelReady ? 1 : 0)
    }

    private var topPredictions: some View {
        HStack {
            ForEach(Array(reader.topThree.enumerated()), id: \.offset) { _, item in
                Text("\(displayName(item.label)) \(Int(item.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
        }
        .frame(height: 24)
    }

    // MARK: Reading output

    private var textPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(reader.text.isEmpty ? "Your signed words appear here" : reader.text + "▍")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(reader.text.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .onChange(of: reader.text) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var suggestionRow: some View {
        HStack {
            ForEach(reader.suggestions, id: \.self) { word in
                Button(word.capitalized) { reader.accept(word) }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(height: 36)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            control("Space", "space") { reader.insertSpace() }
            control("Delete", "delete.left") { reader.deleteLast() }
            control("Clear", "trash") { reader.clear() }
            control(reader.isReading ? "Pause" : "Read", reader.isReading ? "pause.fill" : "play.fill") {
                reader.isReading.toggle()
            }
            Button { reader.speakAll() } label: {
                Label("Speak", systemImage: "speaker.wave.2.fill").labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func control(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }

    private func displayName(_ label: String) -> String {
        switch label.lowercased() {
        case "space": return "␣"
        case "del", "delete": return "⌫"
        case "nothing": return "–"
        default: return label.uppercased()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var reader: SignReader
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "Confidence threshold: %.0f%%", reader.threshold * 100))
                        Slider(value: $reader.threshold, in: 0.4...0.95, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Hold time: %.1f s", reader.holdSeconds))
                        Slider(value: $reader.holdSeconds, in: 0.3...2.0, step: 0.1)
                    }
                } header: {
                    Text("Typing")
                } footer: {
                    Text("A sign is typed when it stays above the threshold for the hold time. Hold twice as long, or lower your hand and sign again, to repeat a letter.")
                }
                Section {
                    Toggle("Auto-space after a pause", isOn: $reader.autoSpace)
                    if reader.autoSpace {
                        VStack(alignment: .leading) {
                            Text(String(format: "Pause length: %.1f s", reader.autoSpaceSeconds))
                            Slider(value: $reader.autoSpaceSeconds, in: 1.0...4.0, step: 0.5)
                        }
                    }
                } header: {
                    Text("Words")
                } footer: {
                    Text("Lower your hand (no confident sign) to finish a word.")
                }
                Section {
                    Toggle("Left-handed signer", isOn: $reader.leftHanded)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("The model was trained on right-handed signs against a plain dark background. Left-handed mode mirrors the image the model sees. A plain, dark background and good light give the best results.")
                }
                Section("Speech") {
                    Toggle("Speak each finished word", isOn: $reader.speakWords)
                }
                Section("Model") {
                    LabeledContent("Model", value: reader.modelReady ? "RapidNet-Ti · 36 signs" : "Missing")
                    LabeledContent("Latency", value: String(format: "%.2f ms", reader.latencyMs))
                    LabeledContent("Frame rate", value: String(format: "%.0f fps", reader.fps))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
