import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

struct SignPrediction {
    let label: String
    let confidence: Float
    let top: [(label: String, confidence: Float)]
    let latencyMs: Double
}

enum ClassifierError: LocalizedError {
    case modelMissing

    var errorDescription: String? {
        "ASLRapidNet.mlmodel is not in the app. Convert best.pth with convert_asl_coreml.py and copy it into ASLReader/."
    }
}

/// Runs the fine-tuned RapidNet ASL model (RapidNet-Ti, classes 0-9 and a-z) on camera frames.
final class SignClassifier {
    /// Same as the training evaluation transform: Resize(224/0.9) + CenterCrop(224),
    /// i.e. the model sees the central 90% of the square crop.
    static let cropFraction: CGFloat = 0.9

    private let request: VNCoreMLRequest
    let labels: [String]

    init() throws {
        guard let url = Bundle.main.url(forResource: "ASLRapidNet", withExtension: "mlmodelc") else {
            throw ClassifierError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all  // Neural Engine when available
        let model = try MLModel(contentsOf: url, configuration: configuration)
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .centerCrop
        labels = (model.modelDescription.classLabels as? [String]) ?? []
    }

    /// Call from the camera queue. Frames arrive already rotated to portrait.
    /// `allowed` restricts the answer to a subset of labels (e.g. letters only), renormalised.
    func classify(_ pixelBuffer: CVPixelBuffer, allowed: Set<String>?) -> SignPrediction? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let side = min(width, height) * Self.cropFraction
        request.regionOfInterest = CGRect(x: (1 - side / width) / 2, y: (1 - side / height) / 2,
                                          width: side / width, height: side / height)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let latency = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard var results = request.results as? [VNClassificationObservation], !results.isEmpty else { return nil }

        var scores = results.map { (label: $0.identifier, confidence: $0.confidence) }
        if let allowed, !allowed.isEmpty {
            results = results.filter { allowed.contains($0.identifier) }
            let total = results.reduce(Float(0)) { $0 + $1.confidence }
            guard total > 0 else { return nil }
            scores = results.map { (label: $0.identifier, confidence: $0.confidence / total) }
        }
        scores.sort { $0.confidence > $1.confidence }
        guard let best = scores.first else { return nil }
        return SignPrediction(label: best.label, confidence: best.confidence,
                              top: Array(scores.prefix(3)), latencyMs: latency)
    }
}
