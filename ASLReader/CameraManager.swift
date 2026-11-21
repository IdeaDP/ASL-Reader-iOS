import AVFoundation
import SwiftUI
import UIKit

/// Owns the capture session and hands portrait-oriented BGRA frames to `onFrame` on a background queue.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Called on the camera queue for every frame that is not dropped. Set before `start`.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Mirror the frames the model sees. The model was trained WITHOUT flips on right-handed
    /// signs seen from the front (like the raw, unmirrored camera image), so this stays off
    /// unless the signer uses their left hand.
    var mirrorModelInput = false

    private let sessionQueue = DispatchQueue(label: "aslreader.camera.session")
    private let frameQueue = DispatchQueue(label: "aslreader.camera.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Configures (or reconfigures) the session for the given camera and starts it.
    /// `completion` runs on the main queue with an error message, or nil on success.
    func start(position: AVCaptureDevice.Position, completion: @escaping (String?) -> Void) {
        sessionQueue.async { [self] in
            let error = configure(position: position)
            if error == nil, !session.isRunning {
                session.startRunning()
            }
            DispatchQueue.main.async { completion(error) }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(position: AVCaptureDevice.Position) -> String? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            return "No \(position == .front ? "front" : "rear") camera found."
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "Cannot use this camera." }
            session.addInput(input)
            currentInput = input
        } catch {
            return "Camera error: \(error.localizedDescription)"
        }

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true  // never queue up stale frames behind the model
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { return "Cannot read camera frames." }
            session.addOutput(output)
        }

        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            // The on-screen preview is mirrored like a selfie camera, but the model input is not:
            // raw front-camera frames show the hand the way the training photos did.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrorModelInput
            }
        }
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }
}

/// Live camera preview. Shown in a square = the centre crop; the model reads the inner 90%.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
