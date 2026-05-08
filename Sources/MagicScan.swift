import SwiftUI
import AVFoundation
import AppKit
import Vision

@main
struct MagicScanApp: App {
    var body: some Scene {
        WindowGroup("MagicScan") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.session)
            if camera.fingerCount > 0 {
                Text("\(camera.fingerCount) finger\(camera.fingerCount == 1 ? "" : "s")")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 24)
            }
        }
        .onAppear { camera.start() }
    }
}

final class CameraController: NSObject, ObservableObject {
    @Published var fingerCount: Int = 0

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "magicscan.camera.session")
    private let videoQueue = DispatchQueue(label: "magicscan.camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()

    // Hand pose. Two hands max so we can sum fingers when both are shown.
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                self?.configureAndRun()
            }
        default:
            return
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else {
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([handPoseRequest])
        } catch {
            return
        }

        let hands = handPoseRequest.results ?? []
        let newFingerCount = hands.reduce(0) { $0 + Self.countExtendedFingers($1) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.fingerCount != newFingerCount {
                self.fingerCount = newFingerCount
            }
        }
    }

    /// For the four long fingers: tip farther from the wrist than the PIP
    /// joint means the finger is extended. The thumb gets its own test —
    /// its IP joint sits too close to the tip for the wrist-distance trick
    /// to be reliable, so we check the angle at the MP joint instead
    /// (folded thumbs bend sharply there; extended thumbs stay near 180°).
    private static func countExtendedFingers(_ obs: VNHumanHandPoseObservation) -> Int {
        guard let points = try? obs.recognizedPoints(.all) else { return 0 }
        guard let wrist = points[.wrist], wrist.confidence > 0.3 else { return 0 }

        var count = 0

        if let cmc = points[.thumbCMC], cmc.confidence > 0.3,
           let mp = points[.thumbMP], mp.confidence > 0.3,
           let tip = points[.thumbTip], tip.confidence > 0.3 {
            let ax = cmc.location.x - mp.location.x
            let ay = cmc.location.y - mp.location.y
            let bx = tip.location.x - mp.location.x
            let by = tip.location.y - mp.location.y
            let mag = hypot(ax, ay) * hypot(bx, by)
            if mag > 0 {
                let cosA = max(-1, min(1, (ax * bx + ay * by) / mag))
                // ~140° — extended thumbs sit near 180°, folded ones drop well below.
                if acos(cosA) > 2.45 { count += 1 }
            }
        }

        let fingers: [(tip: VNHumanHandPoseObservation.JointName,
                       pip: VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP),
            (.middleTip, .middlePIP),
            (.ringTip, .ringPIP),
            (.littleTip, .littlePIP),
        ]

        for (tipName, pipName) in fingers {
            guard
                let tip = points[tipName], tip.confidence > 0.3,
                let pip = points[pipName], pip.confidence > 0.3
            else { continue }
            let tipDist = hypot(tip.location.x - wrist.location.x,
                                tip.location.y - wrist.location.y)
            let pipDist = hypot(pip.location.x - wrist.location.x,
                                pip.location.y - wrist.location.y)
            if tipDist > pipDist { count += 1 }
        }
        return count
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

final class PreviewView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(preview)
        previewLayer = preview
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
