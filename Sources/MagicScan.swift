import SwiftUI
import AVFoundation
import AppKit
import Vision
import SceneKit

@main
struct MagicScanApp: App {
    @StateObject private var camera = CameraController()

    var body: some Scene {
        WindowGroup("MagicScan") {
            ContentView()
                .environmentObject(camera)
                .frame(minWidth: 640, minHeight: 480)
        }

        Window("Orb", id: "orb") {
            OrbView()
                .environmentObject(camera)
                .frame(minWidth: 320, minHeight: 320)
        }
        .defaultSize(width: 480, height: 480)
    }
}

struct ContentView: View {
    @EnvironmentObject var camera: CameraController

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

/// Smoothed orb-window state pushed from the live render loop so that
/// recordings can composite a side-by-side panel matching what's on
/// screen.
struct OrbSnapshot {
    var roll: Float
    var totalPress: Float
    /// Normalized fingertip positions (Vision coords, 0...1), in finger
    /// order: thumb, index, middle, ring, little. Always 5 elements.
    var fingertipPositions: [SIMD2<Float>]
    /// Per-finger curl 0...1, same order as positions.
    var fingertipStrengths: [Float]
    /// Confidence that a hand is currently visible, 0...1.
    var handPresence: Float
    /// Current die orientation. The Coordinator's state machine drives
    /// this — tracking the hand, integrating spin physics, or snapping
    /// to a settled face — and the offscreen recorder applies it
    /// directly so recordings match the live view.
    var dieOrientation: simd_quatf
    /// Result face shown after a throw settles. Nil while tracking or
    /// still spinning.
    var dieResult: Int?
    var lastUpdate: Date
}

/// One detected hand, ready for drawing. Coords are Vision-normalized
/// (origin bottom-left, 0...1).
struct HandPose: Equatable {
    struct Finger: Equatable {
        /// Joint chain base→tip. May be shorter than 4 if some joints had
        /// low confidence — segments are drawn between whatever survives.
        let joints: [CGPoint]
        let extended: Bool
        /// Continuous curl: 0 = fully extended, 1 = fully curled. Drives
        /// orb finger-press depth.
        let pressStrength: Float
    }
    /// Order: thumb, index, middle, ring, little. Always exactly 5.
    let fingers: [Finger]
    /// Palm outline: wrist → thumb CMC → MCP knuckles → wrist.
    let palm: [CGPoint]
    /// Hand roll in radians, derived from wrist→middleMCP angle. 0 means
    /// fingers point up; +π/2 means fingers point right (in image space).
    let roll: Float?
}

final class CameraController: NSObject, ObservableObject {
    @Published var hands: [HandPose] = []
    @Published var fingerCount: Int = 0
    @Published var isRecording: Bool = false
    @Published var dieResult: Int?

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

    private var hasStarted = false

    // Recording state — touched only on videoQueue.
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var recordingURL: URL?
    private var recordingArmed: Bool = false

    // Side-by-side orb compositing — touched only on videoQueue.
    private var recordingIncludesOrb: Bool = false
    private var offscreenOrbScene: SCNScene?
    private var offscreenCrystalNode: SCNNode?
    private var offscreenMarkerNodes: [SCNNode] = []
    private var offscreenOrbRenderer: SCNRenderer?

    // Latest orb state pushed from the live OrbSceneView's render loop.
    private let orbSnapshotLock = NSLock()
    private var latestOrbSnapshot: OrbSnapshot?

    func updateOrbSnapshot(_ snap: OrbSnapshot) {
        orbSnapshotLock.lock()
        latestOrbSnapshot = snap
        orbSnapshotLock.unlock()

        let newResult = snap.dieResult
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dieResult != newResult else { return }
            self.dieResult = newResult
        }
    }

    private func currentOrbSnapshot() -> OrbSnapshot? {
        orbSnapshotLock.lock(); defer { orbSnapshotLock.unlock() }
        return latestOrbSnapshot
    }

    func start() {
        guard !hasStarted else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasStarted = true
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted, let self else { return }
                DispatchQueue.main.async { self.hasStarted = true }
                self.configureAndRun()
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
            self.recordingArmed = true
        }
    }

    private func stopRecording() {
        videoQueue.async { [weak self] in
            guard let self else { return }
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
        let snap = currentOrbSnapshot()
        let orbActive = snap.map { -$0.lastUpdate.timeIntervalSinceNow < 1.0 } ?? false
        self.recordingIncludesOrb = orbActive
        if orbActive && offscreenOrbRenderer == nil {
            setupOffscreenOrbScene()
        }
        let outputWidth = orbActive ? width + height : width
        let outputHeight = height

        let url = makeOutputURL()
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
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

        let outW = CVPixelBufferGetWidth(out)
        let outH = CVPixelBufferGetHeight(out)
        let outRow = CVPixelBufferGetBytesPerRow(out)
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let cameraW = recordingIncludesOrb ? outW - outH : outW
        let cameraBytes = cameraW * 4

        if let outBase = CVPixelBufferGetBaseAddress(out),
           let srcBase = CVPixelBufferGetBaseAddress(source) {
            for y in 0..<outH {
                memcpy(outBase.advanced(by: y * outRow),
                       srcBase.advanced(by: y * srcRow),
                       cameraBytes)
            }

            let cs = CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo.byteOrder32Little.rawValue
                     | CGImageAlphaInfo.premultipliedFirst.rawValue
            if let ctx = CGContext(data: outBase, width: outW, height: outH,
                                   bitsPerComponent: 8, bytesPerRow: outRow,
                                   space: cs, bitmapInfo: info) {
                if recordingIncludesOrb,
                   let orbImage = renderOrbSnapshot(size: CGSize(width: outH, height: outH)) {
                    ctx.draw(orbImage, in: CGRect(x: cameraW, y: 0,
                                                  width: outH, height: outH))
                }
                Self.drawWireframe(in: ctx, hands: hands,
                                   size: CGSize(width: cameraW, height: outH))
            }
        }

        CVPixelBufferUnlockBaseAddress(out, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)

        adaptor.append(out, withPresentationTime: pts)
    }

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

    private func setupOffscreenOrbScene() {
        let (scene, crystal, markers) = OrbSceneView.buildScene()
        let device = MTLCreateSystemDefaultDevice()
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene

        offscreenOrbScene = scene
        offscreenCrystalNode = crystal
        offscreenMarkerNodes = markers
        offscreenOrbRenderer = renderer
    }

    private func renderOrbSnapshot(size: CGSize) -> CGImage? {
        guard let renderer = offscreenOrbRenderer,
              let crystal = offscreenCrystalNode,
              let snap = currentOrbSnapshot() else { return nil }

        OrbSceneView.applySnapshot(snap, toCrystal: crystal,
                                   markers: offscreenMarkerNodes)

        let nsImage = renderer.snapshot(atTime: 0, with: size,
                                         antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
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

    private static func extractPose(_ obs: VNHumanHandPoseObservation) -> HandPose? {
        guard let points = try? obs.recognizedPoints(.all) else { return nil }
        let minConf: VNConfidence = 0.25

        func pt(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > minConf else { return nil }
            return p.location
        }

        guard let wrist = pt(.wrist) else { return nil }

        var fingers: [HandPose.Finger] = []

        // Thumb: chain CMC→MP→IP→Tip. Extended uses angle at MP joint.
        let thumbChain = [pt(.thumbCMC), pt(.thumbMP), pt(.thumbIP), pt(.thumbTip)].compactMap { $0 }
        var thumbExtended = false
        var thumbPress: Float = 0
        if let cmc = pt(.thumbCMC), let mp = pt(.thumbMP), let tip = pt(.thumbTip) {
            let ax = cmc.x - mp.x, ay = cmc.y - mp.y
            let bx = tip.x - mp.x, by = tip.y - mp.y
            let mag = hypot(ax, ay) * hypot(bx, by)
            if mag > 0 {
                let cosA = max(-1, min(1, (ax * bx + ay * by) / mag))
                let angle = acos(cosA)
                thumbExtended = angle > 2.45  // ~140°
                // Remap so a relaxed-straight thumb reads as 0 press and
                // a moderately bent thumb saturates to 1.
                thumbPress = max(0, min(1, Float((2.3 - angle) / 0.9)))
            }
        }
        fingers.append(.init(joints: thumbChain, extended: thumbExtended, pressStrength: thumbPress))

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
            // Continuous press from PIP joint angle. Remap so a relaxed
            // open hand sits at 0 (no press) and ~120° of bend saturates
            // to full press — a literal π-reading is rarely produced even
            // by deliberately straight fingers.
            var press: Float = 0
            if let mcp = pt(f.mcp), let pip = pt(f.pip), let dip = pt(f.dip) {
                let ax = mcp.x - pip.x, ay = mcp.y - pip.y
                let bx = dip.x - pip.x, by = dip.y - pip.y
                let mag = hypot(ax, ay) * hypot(bx, by)
                if mag > 0 {
                    let cosA = max(-1, min(1, (ax * bx + ay * by) / mag))
                    let angle = acos(cosA)
                    press = max(0, min(1, Float((2.5 - angle) / 1.0)))
                }
            }
            fingers.append(.init(joints: chain, extended: extended, pressStrength: press))
        }

        let palm = [pt(.wrist), pt(.thumbCMC), pt(.indexMCP),
                    pt(.middleMCP), pt(.ringMCP), pt(.littleMCP),
                    pt(.wrist)].compactMap { $0 }

        // Hand roll: angle of (wrist→middleMCP) from +y axis. atan2(dx, dy)
        // returns 0 when MCP is directly above wrist (fingers up), positive
        // when MCP is to the right (clockwise tilt in image).
        var roll: Float? = nil
        if let middle = pt(.middleMCP) {
            let dx = Float(middle.x - wrist.x)
            let dy = Float(middle.y - wrist.y)
            roll = atan2(dx, dy)
        }

        return HandPose(fingers: fingers, palm: palm, roll: roll)
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

// MARK: - Orb

struct OrbView: View {
    @EnvironmentObject var camera: CameraController

    var body: some View {
        OrbSceneView(camera: camera, hand: camera.hands.first)
            .background(Color(white: 0.04))
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if let result = camera.dieResult {
                    Text("\(result)")
                        .font(.system(size: 96, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.65),
                                    in: RoundedRectangle(cornerRadius: 28))
                        .padding(.top, 24)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7),
                       value: camera.dieResult)
    }
}

/// Renders a faceted crystal that the viewer can see being manipulated:
/// rotation tracks hand roll, scale tracks total grip, and five
/// color-coded markers float at the fingertip positions in 3D — closer
/// to the crystal as each finger curls.
struct OrbSceneView: NSViewRepresentable {
    let camera: CameraController
    let hand: HandPose?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(white: 0.04, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = true

        let (scene, crystal, markers) = Self.buildScene()
        view.scene = scene

        context.coordinator.crystalNode = crystal
        context.coordinator.markerNodes = markers
        context.coordinator.camera = camera
        view.delegate = context.coordinator

        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.targetHand = hand
    }

    /// Returns (scene, dieNode, fingertipMarkers). Used by both the live
    /// SCNView and the offscreen recorder so recordings match the live
    /// view.
    static func buildScene() -> (SCNScene, SCNNode, [SCNNode]) {
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.04, alpha: 1)

        let camNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = 42
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, 4)
        scene.rootNode.addChildNode(camNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 750
        key.light?.color = NSColor(calibratedRed: 1, green: 0.96, blue: 0.92, alpha: 1)
        key.position = SCNVector3(2.5, 3, 4)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.intensity = 350
        rim.light?.color = NSColor(calibratedRed: 0.5, green: 0.7, blue: 1, alpha: 1)
        rim.position = SCNVector3(-3, -1, -2)
        scene.rootNode.addChildNode(rim)

        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 130
        scene.rootNode.addChildNode(amb)

        let die = SCNNode(geometry: makeDieGeometry())
        scene.rootNode.addChildNode(die)

        let markerColors: [NSColor] = [
            NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1),  // thumb
            NSColor(calibratedRed: 1.0, green: 0.7,  blue: 0.3,  alpha: 1),  // index
            NSColor(calibratedRed: 1.0, green: 1.0,  blue: 0.5,  alpha: 1),  // middle
            NSColor(calibratedRed: 0.4, green: 1.0,  blue: 0.5,  alpha: 1),  // ring
            NSColor(calibratedRed: 0.5, green: 0.7,  blue: 1.0,  alpha: 1),  // little
        ]
        var markers: [SCNNode] = []
        for color in markerColors {
            let geom = SCNSphere(radius: 0.07)
            geom.segmentCount = 24
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.emission.contents = color
            geom.firstMaterial = m
            let node = SCNNode(geometry: geom)
            node.opacity = 0
            scene.rootNode.addChildNode(node)
            markers.append(node)
        }

        return (scene, die, markers)
    }

    /// Apply a snapshot to the die + markers. The orientation comes
    /// straight from the snapshot — the Coordinator's state machine
    /// owns whether the die is tracking the hand, mid-spin, or settled.
    static func applySnapshot(_ snap: OrbSnapshot,
                              toCrystal die: SCNNode,
                              markers: [SCNNode]) {
        die.simdOrientation = snap.dieOrientation
        let s = max(0.6, 1.0 - snap.totalPress * 0.06)
        die.scale = SCNVector3(Double(s), Double(s), Double(s))

        let baseZ: Float = 1.6
        let pressZ: Float = 0.5
        for i in 0..<min(5, markers.count) {
            let pos = snap.fingertipPositions[i]
            let strength = snap.fingertipStrengths[i]
            let ox = (pos.x - 0.5) * 2.5
            let oy = (pos.y - 0.5) * 2.5
            let z  = baseZ - (baseZ - pressZ) * min(1, strength)
            markers[i].position = SCNVector3(Double(ox), Double(oy), Double(z))
            markers[i].opacity = CGFloat(snap.handPresence) *
                                 CGFloat(0.25 + 0.75 * min(1, strength))
        }
    }

    /// Six-faced cube with procedurally-drawn pip face textures laid out
    /// so opposite faces sum to seven (1↔6, 2↔5, 3↔4).
    static func makeDieGeometry() -> SCNGeometry {
        let box = SCNBox(width: 1.4, height: 1.4, length: 1.4, chamferRadius: 0.08)
        // SCNBox material order: front (+Z), right (+X), back (-Z),
        // left (-X), top (+Y), bottom (-Y).
        let faceNumbers = [1, 3, 6, 4, 2, 5]
        box.materials = faceNumbers.map { num in
            let m = SCNMaterial()
            m.diffuse.contents = makePipFaceImage(number: num)
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.55
            m.metalness.contents = 0.0
            return m
        }
        return box
    }

    /// Render one die face (1...6) as a pip pattern over an off-white
    /// background.
    static func makePipFaceImage(number: Int) -> NSImage {
        let size: CGFloat = 256
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.87, alpha: 1).set()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

        NSColor(calibratedRed: 0.15, green: 0.1, blue: 0.05, alpha: 1).set()
        let r: CGFloat = size * 0.075
        let m: CGFloat = size / 2
        let h: CGFloat = size * 0.27

        let layouts: [[(CGFloat, CGFloat)]] = [
            [],
            [(m, m)],
            [(m - h, m + h), (m + h, m - h)],
            [(m - h, m + h), (m, m), (m + h, m - h)],
            [(m - h, m + h), (m + h, m + h), (m - h, m - h), (m + h, m - h)],
            [(m - h, m + h), (m + h, m + h), (m, m), (m - h, m - h), (m + h, m - h)],
            [(m - h, m + h), (m + h, m + h), (m - h, m), (m + h, m), (m - h, m - h), (m + h, m - h)],
        ]

        let n = max(0, min(6, number))
        for (x, y) in layouts[n] {
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r,
                                         width: r * 2, height: r * 2)).fill()
        }

        image.unlockFocus()
        return image
    }

    /// Object-space face normals paired with the number painted on each
    /// face. Matches the material order in `makeDieGeometry`.
    static let dieFaceNormals: [(SIMD3<Float>, Int)] = [
        (SIMD3(0, 0,  1), 1),
        (SIMD3(1, 0,  0), 3),
        (SIMD3(0, 0, -1), 6),
        (SIMD3(-1, 0, 0), 4),
        (SIMD3(0,  1, 0), 2),
        (SIMD3(0, -1, 0), 5),
    ]

    /// Object-space orientation that places the given face number's
    /// normal pointing toward the camera (+Z world).
    static func orientationFor(faceNumber: Int) -> simd_quatf {
        switch faceNumber {
        case 1: return simd_quatf(angle: 0,        axis: SIMD3(0, 1, 0))
        case 2: return simd_quatf(angle:  .pi / 2, axis: SIMD3(1, 0, 0))
        case 3: return simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 1, 0))
        case 4: return simd_quatf(angle:  .pi / 2, axis: SIMD3(0, 1, 0))
        case 5: return simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        case 6: return simd_quatf(angle:  .pi,     axis: SIMD3(1, 0, 0))
        default: return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        }
    }

    enum DieState {
        case tracking   // die orientation slerps toward hand roll
        case spinning   // angular velocity decays to rest
        case settled    // showing a result, waits for next grip
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        weak var crystalNode: SCNNode?
        var markerNodes: [SCNNode] = []
        weak var camera: CameraController?

        var targetHand: HandPose?

        private var smoothedTips: [SIMD2<Float>] = Array(repeating: SIMD2(0.5, 0.5), count: 5)
        private var smoothedStrengths: [Float] = [0, 0, 0, 0, 0]
        private var smoothedRoll: Float = 0
        private var smoothedPresence: Float = 0

        // Die state machine.
        private var dieState: DieState = .tracking
        private var dieOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        private var angularVelocity = SIMD3<Float>(0, 0, 0)
        private var dieResult: Int?
        // Pre-picked target for the current throw; spin blends toward it
        // as it decays so the result is uniform 1-in-6 even if the
        // physics happen to favor certain orientations.
        private var rolledFace: Int?

        // Throw detection. Peak trackers decay each frame so a brief grip
        // followed by an open hand still registers as a throw — testing
        // only adjacent frames is too narrow when smoothing is in play.
        private var peakPress: Float = 0
        private var peakSpeed: Float = 0
        private var prevPalm = SIMD2<Float>(0.5, 0.5)
        private var lastTime: TimeInterval = 0

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastTime > 0 ? Float(min(0.05, time - lastTime)) : 1.0 / 60.0
            lastTime = time

            var targetTips = Array(repeating: SIMD2<Float>(0.5, 0.5), count: 5)
            var targetStrengths: [Float] = [0, 0, 0, 0, 0]
            var targetRoll: Float = 0
            let presenceTarget: Float = (targetHand != nil) ? 1 : 0
            if let hand = targetHand {
                for (i, f) in hand.fingers.prefix(5).enumerated() {
                    if let tip = f.joints.last {
                        targetTips[i] = SIMD2(Float(tip.x), Float(tip.y))
                    }
                    targetStrengths[i] = f.pressStrength
                }
                targetRoll = hand.roll ?? 0
            }

            for i in 0..<5 {
                smoothedTips[i] += (targetTips[i] - smoothedTips[i]) * 0.6
                smoothedStrengths[i] += (targetStrengths[i] - smoothedStrengths[i]) * 0.5
            }
            smoothedRoll += (targetRoll - smoothedRoll) * 0.3
            smoothedPresence += (presenceTarget - smoothedPresence) * 0.2

            let totalPress = smoothedStrengths.reduce(0, +)
            let palm = (smoothedTips.reduce(SIMD2<Float>.zero, +)) / 5
            let palmDelta = palm - prevPalm
            let palmSpeed = sqrt(palmDelta.x * palmDelta.x + palmDelta.y * palmDelta.y) / max(dt, 1e-3)

            // Decay peaks ~5%/frame and ~8%/frame so a high value sticks
            // around for ~1 second after the moment we saw it.
            peakPress = max(peakPress * 0.95, totalPress)
            peakSpeed = max(peakSpeed * 0.92, palmSpeed)

            switch dieState {
            case .tracking:
                let target = simd_quatf(angle: -smoothedRoll, axis: SIMD3<Float>(0, 0, 1))
                dieOrientation = simd_slerp(dieOrientation, target,
                                             min(1, dt * 8))

                // Throw: gripped at some point in the last ~second and
                // hand is now open. Velocity isn't required — opening
                // the fist is enough to roll the die — but if there was
                // motion it scales the spin speed up.
                let releasedFromGrip = peakPress > 1.2 && totalPress < 0.5
                if releasedFromGrip {
                    let throwSpeed = max(palmSpeed, peakSpeed)
                    let baseSpeed: Float = 16
                    let speed = max(baseSpeed, min(50, throwSpeed * 10))
                    let tumble = SIMD3<Float>(
                        Float.random(in: -1...1),
                        Float.random(in: -1...1),
                        Float.random(in: -0.4...0.4)
                    )
                    let raw = SIMD3<Float>(
                        palmDelta.y * 8 + tumble.x,
                        -palmDelta.x * 8 + tumble.y,
                        tumble.z
                    )
                    let rawLen = sqrt(raw.x * raw.x + raw.y * raw.y + raw.z * raw.z)
                    let axis = rawLen > 0.001 ? raw / rawLen : SIMD3<Float>(1, 0, 0)
                    angularVelocity = axis * speed
                    rolledFace = Int.random(in: 1...6)
                    dieResult = nil
                    dieState = .spinning
                    peakPress = 0
                    peakSpeed = 0
                }
            case .spinning:
                let speed = sqrt(angularVelocity.x * angularVelocity.x
                                 + angularVelocity.y * angularVelocity.y
                                 + angularVelocity.z * angularVelocity.z)
                if speed > 0.5 {
                    let axis = angularVelocity / speed
                    let dq = simd_quatf(angle: speed * dt, axis: axis)
                    dieOrientation = simd_mul(dq, dieOrientation)
                    angularVelocity *= exp(-1.0 * dt)

                    // Below ~5 rad/s, blend toward the pre-picked target
                    // orientation so the spin glides smoothly into the
                    // chosen face without a visible snap.
                    if let face = rolledFace, speed < 5 {
                        let target = OrbSceneView.orientationFor(faceNumber: face)
                        let approach = (5 - speed) / 5
                        let step = min(1, approach * dt * 6)
                        dieOrientation = simd_slerp(dieOrientation, target, step)
                    }
                } else {
                    if let face = rolledFace {
                        dieOrientation = OrbSceneView.orientationFor(faceNumber: face)
                        dieResult = face
                    }
                    rolledFace = nil
                    angularVelocity = .zero
                    dieState = .settled
                }
            case .settled:
                if totalPress > 1.2 {
                    dieResult = nil
                    dieState = .tracking
                    peakPress = 0
                    peakSpeed = 0
                }
            }

            prevPalm = palm

            let snap = OrbSnapshot(
                roll: smoothedRoll,
                totalPress: totalPress,
                fingertipPositions: smoothedTips,
                fingertipStrengths: smoothedStrengths,
                handPresence: smoothedPresence,
                dieOrientation: dieOrientation,
                dieResult: dieResult,
                lastUpdate: Date()
            )

            if let die = crystalNode {
                OrbSceneView.applySnapshot(snap, toCrystal: die,
                                           markers: markerNodes)
            }
            camera?.updateOrbSnapshot(snap)
        }
    }
}
