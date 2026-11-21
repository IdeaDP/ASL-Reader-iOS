import AVFoundation
import Combine
import UIKit

/// Which signs the reader accepts. ASL uses the same hand shape for some digits and letters
/// (0/O, 2/V, 6/W), so limiting the set removes those mix-ups.
enum SignSet: String, CaseIterable, Identifiable {
    case letters = "A–Z"
    case digits = "0–9"
    case both = "Both"
    var id: String { rawValue }
}

/// Turns the stream of per-frame predictions into typed text.
///
/// A sign is "typed" once it stays the top prediction above the confidence threshold for
/// `holdSeconds`. To type the same sign twice (e.g. "LL"), keep holding it for twice as long,
/// or lower your hand and sign it again. A pause with no confident sign ends the word
/// (auto-space), which also speaks the word aloud.
final class SignReader: ObservableObject {
    // Live recognition
    @Published private(set) var currentLabel = "–"
    @Published private(set) var confidence: Float = 0
    @Published private(set) var topThree: [(label: String, confidence: Float)] = []
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var latencyMs: Double = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var modelReady = false

    // Reading output
    @Published private(set) var text = ""
    @Published private(set) var suggestions: [String] = []

    // Settings
    @Published var isReading = true
    @Published var signSet: SignSet = .letters { didSet { updateAllowed() } }
    @Published var threshold: Float = 0.70
    @Published var holdSeconds: Double = 0.8
    @Published var autoSpace = true
    @Published var autoSpaceSeconds: Double = 2.0
    @Published var speakWords = true
    @Published var leftHanded = false { didSet { camera.mirrorModelInput = leftHanded; startCamera() } }
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front

    let camera = CameraManager()
    private var classifier: SignClassifier?
    private let speech = AVSpeechSynthesizer()
    private let checker = UITextChecker()
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    /// Read on the camera queue, written on main. Swapped as a whole, so a frame sees either set.
    private var allowedLabels: Set<String>?

    private var candidate = "nothing"
    private var candidateSince = Date()
    private var lastCommitted: String?
    private var lastConfidentTime = Date()
    private var lastFrameTime: Date?

    init() {
        do {
            let classifier = try SignClassifier()
            self.classifier = classifier
            modelReady = true
            updateAllowed()
            camera.onFrame = { [weak self] buffer in
                // camera queue: run the model here, publish on main
                guard let self, let prediction = classifier.classify(buffer, allowed: self.allowedLabels) else { return }
                DispatchQueue.main.async { self.handle(prediction) }
            }
        } catch {
            status = error.localizedDescription
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
    }

    private func updateAllowed() {
        guard let labels = classifier?.labels else { return }
        let isDigit: (String) -> Bool = { $0.count == 1 && $0.first!.isNumber }
        switch signSet {
        case .letters: allowedLabels = Set(labels.filter { !isDigit($0) })
        case .digits: allowedLabels = Set(labels.filter(isDigit))
        case .both: allowedLabels = nil
        }
        candidate = "nothing"
        lastCommitted = nil
    }

    // MARK: Camera

    func startCamera() {
        CameraManager.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.status = "Camera access is off. Allow it in Settings › ASL Reader."
                return
            }
            self.camera.start(position: self.cameraPosition) { error in
                if let error { self.status = error }
                else if self.modelReady { self.status = "Show a sign inside the square" }
            }
        }
    }

    func stopCamera() { camera.stop() }

    func flipCamera() {
        cameraPosition = cameraPosition == .front ? .back : .front
        startCamera()
    }

    // MARK: Recognition → text

    private func handle(_ prediction: SignPrediction) {
        let now = Date()
        if let last = lastFrameTime {
            let instantaneous = 1 / max(now.timeIntervalSince(last), 0.001)
            fps = fps == 0 ? instantaneous : fps * 0.9 + instantaneous * 0.1
        }
        lastFrameTime = now
        latencyMs = latencyMs == 0 ? prediction.latencyMs : latencyMs * 0.9 + prediction.latencyMs * 0.1
        currentLabel = prediction.label
        confidence = prediction.confidence
        topThree = prediction.top

        guard isReading else { holdProgress = 0; return }

        // This model has no "nothing" class: low confidence means no clear sign.
        let label = prediction.confidence >= threshold ? prediction.label : "nothing"
        if label != candidate {
            candidate = label
            candidateSince = now
        }
        if label == "nothing" {
            lastCommitted = nil  // hand dropped / changed: the same sign may be typed again
            holdProgress = 0
            if autoSpace, now.timeIntervalSince(lastConfidentTime) >= autoSpaceSeconds,
               !text.isEmpty, !text.hasSuffix(" ") {
                insertSpace()
            }
            return
        }
        lastConfidentTime = now
        let needed = label == lastCommitted ? holdSeconds * 2 : holdSeconds
        let held = now.timeIntervalSince(candidateSince)
        holdProgress = min(held / needed, 1)
        if held >= needed {
            type(label)
            lastCommitted = label
            candidateSince = now
            holdProgress = 0
        }
    }

    private func type(_ label: String) {
        haptic.impactOccurred()
        switch label.lowercased() {
        case "space": insertSpace()          // supported if a model has these classes
        case "del", "delete": deleteLast()
        default: text += label.uppercased()
        }
        refreshSuggestions()
    }

    // MARK: Editing (also used by the on-screen buttons)

    func insertSpace() {
        guard !text.isEmpty, !text.hasSuffix(" ") else { return }
        let word = currentWord
        text += " "
        if speakWords, !word.isEmpty { say(word) }
        refreshSuggestions()
    }

    func deleteLast() {
        if !text.isEmpty { text.removeLast() }
        refreshSuggestions()
    }

    func clear() {
        text = ""
        lastCommitted = nil
        refreshSuggestions()
    }

    func accept(_ suggestion: String) {
        let word = currentWord
        text.removeLast(word.count)
        text += suggestion.uppercased() + " "
        if speakWords { say(suggestion) }
        lastConfidentTime = Date()
        refreshSuggestions()
    }

    func speakAll() {
        let sentence = text.trimmingCharacters(in: .whitespaces)
        if !sentence.isEmpty { say(sentence) }
    }

    // MARK: Helpers

    private var currentWord: String {
        guard !text.hasSuffix(" ") else { return "" }
        return text.split(separator: " ").last.map(String.init) ?? ""
    }

    private func refreshSuggestions() {
        let word = currentWord.lowercased()
        guard word.count >= 2, word.allSatisfy(\.isLetter) else { suggestions = []; return }
        let range = NSRange(location: 0, length: (word as NSString).length)
        var options: [String] = []
        if checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
            options.append(word)  // already a real word
        }
        options += checker.completions(forPartialWordRange: range, in: word, language: "en_US") ?? []
        options += checker.guesses(forWordRange: range, in: word, language: "en_US") ?? []
        var seen = Set<String>()
        suggestions = Array(options.filter { seen.insert($0.lowercased()).inserted }.prefix(3))
    }

    private func say(_ words: String) {
        let utterance = AVSpeechUtterance(string: words.lowercased())
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utterance)
    }
}
