//
//  CameraCapture.swift
//  Plain AVFoundation camera capture used by AR-Layer-0-iOS to close the
//  loop with the laptop. AR-Layer 2 will replace the inside of `start()`
//  with an ARSession and start emitting per-ARFrame poses; the public
//  surface (CapturedFrame stream + stop) stays the same.
//

import AVFoundation
import UIKit

@MainActor
final class CameraCapture: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var capturedCount = 0
    @Published var previewLayer: AVCaptureVideoPreviewLayer?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var captureTimer: Timer?
    private(set) var frames: [CapturedFrame] = []
    private var targetCount = 30
    private var nextID = 0
    private var onFinished: (([CapturedFrame]) -> Void)?

    func configure() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw NSError(domain: "Splattr.Cam", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Camera permission denied. Enable it in Settings → Splattr."
            ])
        }
        try setUpSession()
    }

    func startCapturing(targetCount: Int,
                        intervalSeconds: Double,
                        completion: @escaping ([CapturedFrame]) -> Void) {
        self.targetCount = targetCount
        self.onFinished = completion
        self.frames.removeAll()
        self.capturedCount = 0
        self.nextID = 0

        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                Task { @MainActor in self?.isRunning = true }
            }
        }
        // Snap one immediately so the user sees progress, then tick.
        snap()
        captureTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            self?.snap()
        }
    }

    func stop() {
        captureTimer?.invalidate()
        captureTimer = nil
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
                Task { @MainActor in self?.isRunning = false }
            }
        }
    }

    // MARK: - Internal

    private func setUpSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NSError(domain: "Splattr.Cam", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No back camera found."
            ])
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw NSError(domain: "Splattr.Cam", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't attach camera input/output."
            ])
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
    }

    private func snap() {
        guard nextID < targetCount else {
            captureTimer?.invalidate(); captureTimer = nil
            let captured = frames
            onFinished?(captured)
            return
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraCapture: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let img = UIImage(data: data)
        let w = Int(img?.size.width ?? 1920)
        let h = Int(img?.size.height ?? 1080)
        Task { @MainActor in
            let id = self.nextID
            self.nextID += 1
            let f = CapturedFrame(id: id,
                                  timestamp: Date(),
                                  jpegData: data,
                                  width: w,
                                  height: h)
            self.frames.append(f)
            self.capturedCount = self.frames.count
        }
    }
}
