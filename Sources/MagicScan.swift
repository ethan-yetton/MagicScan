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
        CameraPreview(session: camera.session, hands: camera.hands)
            .overlay(alignment: .topLeading) {
                if camera.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("REC").font(.caption.weight(.bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(20)
                }
            }
            .overlay(alignment: .bottom) {
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
            .overlay(alignment: .bottomTrailing) {
                Button { camera.toggleRecording() } label: {
                    ZStack {
                        Circle().fill(.black.opacity(0.6)).frame(width: 56, height: 56)
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 4).fill(.red).frame(width: 22, height: 22)
                        } else {
                            Circle().fill(.red).frame(width: 22, height: 22)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(camera.isRecording ? "Stop recording" : "Start recording")
                .padding(24)
            }
            .onAppear { camera.start() }
    }
}

/// One detected hand, ready for drawing. Coords are Vision-normalized
/// (origin bottom-left, 0...1).
struct HandPose: Equatable {
    struct Finger: Equatable {
        /// Joint chain base→tip. May be shorter than 4 if some joints had
        /// low confidence — segments are drawn between whatever survives.
        let joints: [CGPoint]
        let extended: Bool
    }
    /// Order: thumb, index, middle, ring, little.
    let fingers: [Finger]
    /// Palm outline: wrist → thumb CMC → MCP knuckles → wrist.
    let palm: [CGPoint]
}

final class CameraController: NSObject, ObservableObject {
    @Published var hands: [HandPose] = []
    @Published var fingerCount: Int = 0
    @Published var isRecording: Bool = false

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

    // Recording state — touched only on videoQueue.
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var recordingURL: URL?
    private var recordingArmed: Bool = false

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
            // BGRA so we can draw the wireframe directly via CGContext when
            // recording. Vision handles BGRA fine.
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        videoQueue.async { [weak self] in
            guard let self, self.assetWriter == nil else { return }
            // Defer writer creation to the next frame so we can size it
            // from the actual pixel buffer dimensions.
            self.recordingArmed = true
        }
    }

    private func stopRecording() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            // Aborted before the first frame ever set up the writer.
            if self.recordingArmed && self.assetWriter == nil {
                self.recordingArmed = false
                return
            }
            guard let writer = self.assetWriter, let input = self.videoInput else { return }
            let url = self.recordingURL
            input.markAsFinished()
            self.assetWriter = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
            self.recordingStartTime = nil
            self.recordingURL = nil
            writer.finishWriting {
                DispatchQueue.main.async {
                    self.isRecording = false
                    if let url, FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    private func setupAssetWriter(width: Int, height: Int) -> Bool {
        let url = makeOutputURL()
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attrs
            )

            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else {
                NSLog("MagicScan: writer start failed — \(writer.error?.localizedDescription ?? "?")")
                return false
            }

            self.assetWriter = writer
            self.videoInput = input
            self.pixelBufferAdaptor = adaptor
            self.recordingURL = url
            self.recordingStartTime = nil

            DispatchQueue.main.async { self.isRecording = true }
            return true
        } catch {
            NSLog("MagicScan: writer setup failed — \(error)")
            return false
        }
    }

    private func makeOutputURL() -> URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = movies.appendingPathComponent("MagicScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return dir.appendingPathComponent("MagicScan-\(f.string(from: Date())).mp4")
    }

    private func appendFrame(source: CVPixelBuffer, hands: [HandPose], pts: CMTime) {
        guard let writer = assetWriter, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor,
              let pool = adaptor.pixelBufferPool else { return }

        if recordingStartTime == nil {
            recordingStartTime = pts
            writer.startSession(atSourceTime: pts)
        }

        var outBuf: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
        guard status == kCVReturnSuccess, let out = outBuf else { return }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])

        let w = CVPixelBufferGetWidth(out)
        let h = CVPixelBufferGetHeight(out)
        let outRow = CVPixelBufferGetBytesPerRow(out)
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let pixelBytes = w * 4

        if let outBase = CVPixelBufferGetBaseAddress(out),
           let srcBase = CVPixelBufferGetBaseAddress(source) {
            // Row-by-row copy — pool buffers and capture buffers may have
            // different row padding even at matching widths.
            for y in 0..<h {
                memcpy(outBase.advanced(by: y * outRow),
                       srcBase.advanced(by: y * srcRow),
                       pixelBytes)
            }

            // BGRA in memory == byteOrder32Little + premultipliedFirst in CG.
            let cs = CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo.byteOrder32Little.rawValue
                     | CGImageAlphaInfo.premultipliedFirst.rawValue
            if let ctx = CGContext(data: outBase, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: outRow,
                                   space: cs, bitmapInfo: info) {
                Self.drawWireframe(in: ctx, hands: hands,
                                   size: CGSize(width: w, height: h))
            }
        }

        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)

        adaptor.append(out, withPresentationTime: pts)
    }

    /// Renders the wireframe directly into the recording's pixel buffer.
    /// CG user space is bottom-left, matching Vision's normalized coords —
    /// so a Vision (x, y) maps straight to (x*w, y*h) with no flip.
    private static func drawWireframe(in ctx: CGContext, hands: [HandPose], size: CGSize) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for hand in hands {
            if hand.palm.count >= 2 {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
                ctx.setLineWidth(2)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: hand.palm[0].x * size.width,
                                     y: hand.palm[0].y * size.height))
                for p in hand.palm.dropFirst() {
                    ctx.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
                ctx.strokePath()
            }
            for finger in hand.fingers {
                guard finger.joints.count >= 2 else { continue }
                if finger.extended {
                    ctx.setStrokeColor(NSColor.systemGreen.cgColor)
                    ctx.setLineWidth(5)
                } else {
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
                    ctx.setLineWidth(2.5)
                }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: finger.joints[0].x * size.width,
                                     y: finger.joints[0].y * size.height))
                for p in finger.joints.dropFirst() {
                    ctx.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                }
                ctx.strokePath()

                if finger.extended, let tip = finger.joints.last {
                    let r: CGFloat = 8
                    let center = CGPoint(x: tip.x * size.width, y: tip.y * size.height)
                    let rect = CGRect(x: center.x - r, y: center.y - r,
                                      width: r * 2, height: r * 2)
                    ctx.setFillColor(NSColor.systemGreen.cgColor)
                    ctx.fillEllipse(in: rect)
                    ctx.setStrokeColor(NSColor.white.cgColor)
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: rect)
                }
            }
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

        let observations = handPoseRequest.results ?? []
        let newHands = observations.compactMap { Self.extractPose($0) }
        let newFingerCount = newHands.reduce(0) { acc, h in
            acc + h.fingers.lazy.filter(\.extended).count
        }

        // Lazy writer setup so we can size from the actual frame.
        if recordingArmed {
            recordingArmed = false
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            _ = setupAssetWriter(width: w, height: h)
        }

        if assetWriter != nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            appendFrame(source: pixelBuffer, hands: newHands, pts: pts)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hands = newHands
            if self.fingerCount != newFingerCount {
                self.fingerCount = newFingerCount
            }
        }
    }

    /// Build a HandPose from one Vision observation: collect joint chains
    /// for drawing and decide which fingers are extended. The extension
    /// test for the four long fingers compares tip-to-wrist vs PIP-to-wrist
    /// distance; the thumb gets an angle-at-MP test because its IP joint
    /// sits too close to the tip for the distance trick to work.
    private static func extractPose(_ obs: VNHumanHandPoseObservation) -> HandPose? {
        guard let points = try? obs.recognizedPoints(.all) else { return nil }
        let minConf: VNConfidence = 0.25

        func pt(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > minConf else { return nil }
            return p.location
        }

        guard let wrist = pt(.wrist) else { return nil }

        var fingers: [HandPose.Finger] = []

        let thumbChain = [pt(.thumbCMC), pt(.thumbMP), pt(.thumbIP), pt(.thumbTip)].compactMap { $0 }
        var thumbExtended = false
        if let cmc = pt(.thumbCMC), let mp = pt(.thumbMP), let tip = pt(.thumbTip) {
            let ax = cmc.x - mp.x, ay = cmc.y - mp.y
            let bx = tip.x - mp.x, by = tip.y - mp.y
            let mag = hypot(ax, ay) * hypot(bx, by)
            if mag > 0 {
                let cosA = max(-1, min(1, (ax * bx + ay * by) / mag))
                // ~140°: extended thumbs sit near 180°, folded ones drop well below.
                thumbExtended = acos(cosA) > 2.45
            }
        }
        fingers.append(.init(joints: thumbChain, extended: thumbExtended))

        let longFingers: [(mcp: VNHumanHandPoseObservation.JointName,
                           pip: VNHumanHandPoseObservation.JointName,
                           dip: VNHumanHandPoseObservation.JointName,
                           tip: VNHumanHandPoseObservation.JointName)] = [
            (.indexMCP, .indexPIP, .indexDIP, .indexTip),
            (.middleMCP, .middlePIP, .middleDIP, .middleTip),
            (.ringMCP, .ringPIP, .ringDIP, .ringTip),
            (.littleMCP, .littlePIP, .littleDIP, .littleTip),
        ]
        for f in longFingers {
            let chain = [pt(f.mcp), pt(f.pip), pt(f.dip), pt(f.tip)].compactMap { $0 }
            var extended = false
            if let tip = pt(f.tip), let pip = pt(f.pip) {
                let tipDist = hypot(tip.x - wrist.x, tip.y - wrist.y)
                let pipDist = hypot(pip.x - wrist.x, pip.y - wrist.y)
                extended = tipDist > pipDist
            }
            fingers.append(.init(joints: chain, extended: extended))
        }

        let palm = [pt(.wrist), pt(.thumbCMC), pt(.indexMCP),
                    pt(.middleMCP), pt(.ringMCP), pt(.littleMCP),
                    pt(.wrist)].compactMap { $0 }

        return HandPose(fingers: fingers, palm: palm)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let hands: [HandPose]

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.update(hands: hands)
    }
}

final class PreviewView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let overlay = CALayer()
    private var hands: [HandPose] = []

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

        overlay.frame = bounds
        overlay.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        overlay.frame = bounds
        redraw()
    }

    func update(hands: [HandPose]) {
        self.hands = hands
        redraw()
    }

    private func redraw() {
        guard let preview = previewLayer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }

        for hand in hands {
            if hand.palm.count >= 2 {
                let path = CGMutablePath()
                path.move(to: convert(visionPoint: hand.palm[0], in: preview))
                for p in hand.palm.dropFirst() {
                    path.addLine(to: convert(visionPoint: p, in: preview))
                }
                let layer = CAShapeLayer()
                layer.path = path
                layer.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
                layer.fillColor = NSColor.clear.cgColor
                layer.lineWidth = 1.5
                layer.lineJoin = .round
                overlay.addSublayer(layer)
            }

            for finger in hand.fingers {
                guard finger.joints.count >= 2 else { continue }

                let path = CGMutablePath()
                path.move(to: convert(visionPoint: finger.joints[0], in: preview))
                for p in finger.joints.dropFirst() {
                    path.addLine(to: convert(visionPoint: p, in: preview))
                }
                let line = CAShapeLayer()
                line.path = path
                line.fillColor = NSColor.clear.cgColor
                line.lineCap = .round
                line.lineJoin = .round
                if finger.extended {
                    line.strokeColor = NSColor.systemGreen.cgColor
                    line.lineWidth = 4
                } else {
                    line.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
                    line.lineWidth = 2
                }
                overlay.addSublayer(line)

                if finger.extended, let tip = finger.joints.last {
                    let p = convert(visionPoint: tip, in: preview)
                    let r: CGFloat = 6
                    let dot = CAShapeLayer()
                    dot.path = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2),
                                      transform: nil)
                    dot.fillColor = NSColor.systemGreen.cgColor
                    dot.strokeColor = NSColor.white.cgColor
                    dot.lineWidth = 1.5
                    overlay.addSublayer(dot)
                }
            }
        }

        CATransaction.commit()
    }

    private func convert(visionPoint p: CGPoint,
                         in preview: AVCaptureVideoPreviewLayer) -> CGPoint {
        // Vision: origin bottom-left. Metadata-output: origin top-left.
        // macOS only exposes the rect-based converter, so we round-trip
        // through a zero-size rect — and flip y once more on the way out
        // because layerRectConverted returns top-down coords while our
        // overlay sublayer is in macOS bottom-up CALayer coords.
        let metaRect = CGRect(x: p.x, y: 1 - p.y, width: 0, height: 0)
        let r = preview.layerRectConverted(fromMetadataOutputRect: metaRect)
        return CGPoint(x: r.origin.x, y: preview.bounds.height - r.origin.y)
    }
}
