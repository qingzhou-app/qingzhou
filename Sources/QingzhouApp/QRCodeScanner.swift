#if os(iOS)
import SwiftUI
import AVFoundation

/// iOS 二维码扫描视图。SwiftUI 包装 `AVCaptureSession`。
///
/// 使用注意：宿主 app 必须在 Info.plist 声明 `NSCameraUsageDescription`，
/// 否则首次启动相机会立刻 crash。当前 Apps/iOS/Info.plist 已写好。
public struct QRCodeScannerView: UIViewControllerRepresentable {
    public var onScan: (String) -> Void
    public var onError: ((String) -> Void)? = nil

    public init(onScan: @escaping (String) -> Void, onError: ((String) -> Void)? = nil) {
        self.onScan = onScan
        self.onError = onError
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScan = onScan
        vc.onError = onError
        return vc
    }

    public func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) { }

    public final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        var onError: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            setupCamera()
        }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.session.startRunning()
                }
            }
        }

        public override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        private func setupCamera() {
            guard let device = AVCaptureDevice.default(for: .video) else {
                onError?(L("没有可用摄像头")); return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    onError?(L("无法添加摄像头输入")); return
                }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    onError?(L("无法添加 QR 输出")); return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]

                let layer = AVCaptureVideoPreviewLayer(session: session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = view.bounds
                view.layer.addSublayer(layer)
                previewLayer = layer
            } catch {
                onError?("\(error)")
            }
        }

        // Swift 6：UIViewController 默认 @MainActor，但 AVFoundation 的 delegate 协议不是 ——
        // 所以这个方法要标 nonisolated，然后 hop 回 main 改 UI 状态。
        nonisolated public func metadataOutput(_ output: AVCaptureMetadataOutput,
                                                didOutput metadataObjects: [AVMetadataObject],
                                                from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            Task { @MainActor [weak self] in
                self?.session.stopRunning()
                self?.onScan?(value)
            }
        }
    }
}
#endif
