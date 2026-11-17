import AVFoundation
import Foundation
import ImageIO
import Photos
import QuartzCore
import UIKit

/// 相机会话管理：预览采集、节流评分、拍照与写入相册。
///
/// 刻意不使用 Swift Concurrency 的严格隔离模型，全部走串行队列 + 主线程回写，
/// 这样在 Swift 5 语言模式下行为最稳定，也不受 Swift 6 隔离规则影响。
final class CameraController: NSObject, ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var score = CompositionScore()
    @Published private(set) var permissionDenied = false
    @Published private(set) var isFrontCamera = false
    @Published private(set) var isCapturing = false
    @Published var autoCaptureEnabled = false {
        didSet {
            if !autoCaptureEnabled { consecutiveGood = 0 }
        }
    }
    @Published var toast: String?

    /// 自动快门阈值
    var autoCaptureThreshold = 85
    /// 连续多少帧达标才触发，避免抖动误拍
    private let autoCaptureStreak = 4

    let session = AVCaptureSession()

    // MARK: - 内部

    private let sessionQueue = DispatchQueue(label: "guangying.session")
    private let videoQueue = DispatchQueue(label: "guangying.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let scorer = CompositionScorer()

    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var lastAnalysisTime: CFTimeInterval = 0
    private var lastCaptureTime: CFTimeInterval = 0
    private var consecutiveGood = 0

    /// 分析节流间隔（秒）。每帧都推理会明显发热掉帧。
    private let analysisInterval: CFTimeInterval = 0.22

    // MARK: - 生命周期

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndRun()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = Self.device(for: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        applyPortraitOrientation()
        session.commitConfiguration()
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInDualCamera,
            .builtInTripleCamera
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        ).devices.first
    }

    /// 竖屏预览。iOS 17 起了新 API，这里兼顾两版。
    private func applyPortraitOrientation() {
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection, connection.isVideoOrientationSupported else { continue }
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - 前后摄像头切换

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self, let current = self.videoInput else { return }
            let target: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let device = Self.device(for: target),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.applyPortraitOrientation()
                DispatchQueue.main.async {
                    self.isFrontCamera = (target == .front)
                    self.scorer.reset()
                }
            } else {
                self.session.addInput(current)
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: - 拍照

    func capturePhoto() {
        let now = CACurrentMediaTime()
        guard now - lastCaptureTime > 0.8 else { return }
        lastCaptureTime = now

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            DispatchQueue.main.async { self.isCapturing = true }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func savePhotoData(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self?.toast = "未获得相册写入权限，请到设置里开启"
                    self?.isCapturing = false
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    self?.toast = success ? "已保存到相册" : "保存失败，请重试"
                    self?.isCapturing = false
                }
            }
        }
    }
}

// MARK: - 视频帧

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= analysisInterval else { return }
        lastAnalysisTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation: CGImagePropertyOrientation = isFrontCamera ? .leftMirrored : .right
        let result = scorer.evaluate(pixelBuffer: pixelBuffer, orientation: orientation)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.score = result
            self.handleAutoCaptureIfNeeded(score: result.total)
        }
    }

    private func handleAutoCaptureIfNeeded(score: Int) {
        guard autoCaptureEnabled, !isCapturing else {
            consecutiveGood = 0
            return
        }
        if score >= autoCaptureThreshold {
            consecutiveGood += 1
            if consecutiveGood >= autoCaptureStreak {
                consecutiveGood = 0
                capturePhoto()
            }
        } else {
            consecutiveGood = 0
        }
    }
}

// MARK: - 拍照回调

extension CameraController: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { [weak self] in
                self?.toast = "拍照失败，请重试"
                self?.isCapturing = false
            }
            return
        }
        savePhotoData(data)
    }
}
