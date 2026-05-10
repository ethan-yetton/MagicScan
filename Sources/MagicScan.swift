import SwiftUI
import AVFoundation
import AppKit
import Vision
import SceneKit
import ScreenCaptureKit

@main
struct MagicScanApp: App {
    @StateObject private var camera = CameraController()

    var body: some Scene {
        WindowGroup("MagicScan") {
            ContentView()
                .environmentObject(camera)
                .frame(minWidth: 640, minHeight: 480)
        }

        Window("Die Roller", id: "orb") {
            OrbView()
                .environmentObject(camera)
                .frame(minWidth: 320, minHeight: 320)
        }
        .defaultSize(width: 480, height: 480)

        Settings {
            SettingsView()
        }
    }
}

enum HandPreference: String, CaseIterable, Identifiable {
    case right, left
    var id: String { rawValue }
    var label: String {
        switch self {
        case .right: return "Right hand"
        case .left: return "Left hand"
        }
    }
    var chirality: VNChirality {
        switch self {
        case .right: return .right
        case .left: return .left
        }
    }
    static let storageKey = "preferredHand"
    static var current: HandPreference {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return HandPreference(rawValue: raw) ?? .right
    }
}

enum DieKind: String, CaseIterable, Identifiable {
    case d6, d20
    var id: String { rawValue }
    var label: String {
        switch self {
        case .d6: return "Casino"
        case .d20: return "Adventure"
        }
    }
    var faceCount: Int {
        switch self {
        case .d6: return 6
        case .d20: return 20
        }
    }
    static let storageKey = "dieKind"
    static var current: DieKind {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return DieKind(rawValue: raw) ?? .d6
    }
}

/// How much forward (toward-camera) motion is needed to qualify a
/// gripped hand as a throw. Lower threshold = easier to fire, at the
/// cost of more false positives from incidental motion.
enum ThrowSensitivity: String, CaseIterable, Identifiable {
    case strict, normal, sensitive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .strict: return "Strict"
        case .normal: return "Normal"
        case .sensitive: return "Sensitive"
        }
    }
    /// Minimum forward displacement (growth in normalized knuckle span)
    /// since the grip latched. Path A (slow deliberate throws) — paired
    /// with a small palm-speed gate.
    var forwardThreshold: Float {
        switch self {
        case .strict: return 0.04
        case .normal: return 0.02
        case .sensitive: return 0.008
        }
    }

    /// Path B threshold — peak palm speed for "fast throw" detection.
    /// Empirically the user's lateral / off-screen throws produce
    /// peakSpd of 5–10 with near-zero knuckle-span growth, so a pure
    /// growth-based check misses them entirely. This catches them
    /// without firing on clearly-backward wind-ups (which we filter
    /// separately by requiring growth > -0.005).
    var peakSpeedThreshold: Float {
        switch self {
        case .strict: return 3.0
        case .normal: return 1.5
        case .sensitive: return 0.8
        }
    }
    static let storageKey = "throwSensitivity"
    static var current: ThrowSensitivity {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return ThrowSensitivity(rawValue: raw) ?? .normal
    }
}

struct SettingsView: View {
    @AppStorage(HandPreference.storageKey) private var preferred: String = HandPreference.right.rawValue
    @AppStorage(DieKind.storageKey) private var die: String = DieKind.d6.rawValue
    @AppStorage(ThrowSensitivity.storageKey) private var sensitivity: String = ThrowSensitivity.normal.rawValue

    var body: some View {
        Form {
            Picker("Tracked hand", selection: $preferred) {
                ForEach(HandPreference.allCases) { pref in
                    Text(pref.label).tag(pref.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Mode", selection: $die) {
                ForEach(DieKind.allCases) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Throw sensitivity", selection: $sensitivity) {
                ForEach(ThrowSensitivity.allCases) { s in
                    Text(s.label).tag(s.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct ContentView: View {
    @EnvironmentObject var camera: CameraController
    @AppStorage(DieKind.storageKey) private var dieKind: String = DieKind.d6.rawValue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            if dieKind == DieKind.d20.rawValue {
                HStack(spacing: 0) {
                    cameraPreview(embedOrb: true)
                    DungeonMapView { camera.appendGameMessage($0) }
                }
                GameTextBox(messages: camera.gameMessages)
            } else {
                cameraPreview(embedOrb: false)
            }
        }
        .onAppear {
            camera.start()
            // Only open the standalone die-roller window in Casino
            // mode. Adventure mode embeds the die in the main window.
            if dieKind == DieKind.d6.rawValue {
                openWindow(id: "orb")
            }
        }
        .onChange(of: dieKind) { newValue in
            if newValue == DieKind.d20.rawValue {
                dismissWindow(id: "orb")
            } else {
                openWindow(id: "orb")
            }
        }
    }

    private func cameraPreview(embedOrb: Bool) -> some View {
        CameraPreview(session: camera.session, hands: camera.hands)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    if camera.isRecording {
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text("REC").font(.caption.weight(.bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                    }
                    if embedOrb {
                        EmbeddedOrbView()
                            .environmentObject(camera)
                            .frame(width: 180, height: 180)
                    }
                }
                .padding(20)
            }
            .overlay(alignment: .topTrailing) {
                if !camera.debugText.isEmpty {
                    Text(camera.debugText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.black.opacity(0.7),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
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
    }
}

enum DungeonTileKind {
    case empty, chest, enemy, door
}

struct DungeonTile {
    var kind: DungeonTileKind
    var revealed: Bool
}

struct DungeonMap {
    static let columns = 16
    static let rows = 12

    var tiles: [[DungeonTile]]
    var floor: Int

    static func make(floor: Int) -> DungeonMap {
        var grid: [[DungeonTile]] = (0..<rows).map { _ in
            (0..<columns).map { _ in
                DungeonTile(kind: randomKind(), revealed: false)
            }
        }
        // Guarantee at least one door so the floor is always escapable.
        let hasDoor = grid.flatMap { $0 }.contains { $0.kind == .door }
        if !hasDoor {
            let r = Int.random(in: 0..<rows)
            let c = Int.random(in: 0..<columns)
            grid[r][c].kind = .door
        }
        // Spawn point: center, forced empty and pre-revealed.
        let sr = rows / 2, sc = columns / 2
        grid[sr][sc].kind = .empty
        grid[sr][sc].revealed = true
        return DungeonMap(tiles: grid, floor: floor)
    }

    private static func randomKind() -> DungeonTileKind {
        switch Double.random(in: 0..<1) {
        case ..<0.74: return .empty
        case ..<0.86: return .chest
        case ..<0.96: return .enemy
        default:      return .door
        }
    }

    func canReveal(row: Int, col: Int) -> Bool {
        guard row >= 0, row < Self.rows, col >= 0, col < Self.columns else { return false }
        if tiles[row][col].revealed { return false }
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nr = row + dr, nc = col + dc
            if nr >= 0, nr < Self.rows, nc >= 0, nc < Self.columns,
               tiles[nr][nc].revealed {
                return true
            }
        }
        return false
    }

    mutating func reveal(row: Int, col: Int) -> DungeonTileKind? {
        guard canReveal(row: row, col: col) else { return nil }
        tiles[row][col].revealed = true
        return tiles[row][col].kind
    }
}

struct DungeonMapView: View {
    @State private var map = DungeonMap.make(floor: 1)
    var log: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let cols = DungeonMap.columns
            let rows = DungeonMap.rows
            let side = min(geo.size.width / Double(cols),
                           geo.size.height / Double(rows))
            ZStack {
                Color(white: 0.06)
                VStack(spacing: 1) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 1) {
                            ForEach(0..<cols, id: \.self) { c in
                                tileView(row: r, col: c)
                                    .frame(width: max(side - 1, 0),
                                           height: max(side - 1, 0))
                            }
                        }
                    }
                }
                .frame(width: side * Double(cols), height: side * Double(rows))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .topLeading) {
            Text("FLOOR \(map.floor)")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundColor(Color(white: 0.6))
                .padding(8)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(white: 0.25))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private func tileView(row: Int, col: Int) -> some View {
        let tile = map.tiles[row][col]
        let reachable = map.canReveal(row: row, col: col)
        Button {
            handleTap(row: row, col: col)
        } label: {
            ZStack {
                Rectangle().fill(tileFill(tile: tile, reachable: reachable))
                if tile.revealed {
                    Text(glyph(for: tile.kind))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(glyphColor(for: tile.kind))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!tile.revealed && !reachable)
    }

    private func handleTap(row: Int, col: Int) {
        let tile = map.tiles[row][col]
        if tile.revealed {
            if tile.kind == .door {
                map = DungeonMap.make(floor: map.floor + 1)
                log("You descend to floor \(map.floor).")
            }
            return
        }
        guard let kind = map.reveal(row: row, col: col) else { return }
        switch kind {
        case .empty: log("You step into an empty space.")
        case .chest: log("You find a treasure chest.")
        case .enemy: log("You spot an enemy.")
        case .door:  log("You find a door leading down. Click again to descend.")
        }
    }

    private func tileFill(tile: DungeonTile, reachable: Bool) -> Color {
        if tile.revealed { return Color(white: 0.28) }
        return reachable ? Color(white: 0.22) : Color(white: 0.10)
    }

    private func glyph(for kind: DungeonTileKind) -> String {
        switch kind {
        case .empty: return "·"
        case .chest: return "$"
        case .enemy: return "E"
        case .door:  return "⌂"
        }
    }

    private func glyphColor(for kind: DungeonTileKind) -> Color {
        switch kind {
        case .empty: return Color(white: 0.55)
        case .chest: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .enemy: return Color(red: 0.92, green: 0.32, blue: 0.32)
        case .door:  return Color(red: 0.40, green: 0.78, blue: 0.95)
        }
    }
}

struct GameTextBox: View {
    let messages: [String]
    private static let bottomAnchor = "game-text-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(messages.indices, id: \.self) { i in
                        Text(messages[i])
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundColor(Color(white: 0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Always-present zero-height sentinel at the very end.
                    // Scrolling to this with anchor .bottom reliably parks
                    // the latest message fully in view, even if the new
                    // row's frame hasn't been measured yet by the time
                    // scrollTo runs.
                    Color.clear
                        .frame(height: 0.5)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .frame(height: 160)
            .background(Color(white: 0.06))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(white: 0.25))
                    .frame(height: 1)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: messages.count) { _ in
                // Snap immediately so the bottom is correct even if the
                // animated follow-up gets interrupted, then animate the
                // visual settle once SwiftUI has laid out the new row.
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
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
    /// Knuckle span (indexMCP→littleMCP) in normalized image coords. Grows
    /// as the hand moves toward the camera and is invariant to finger
    /// curl, so dSize/dt > 0 reads as "forward motion." 0 if joints
    /// weren't confidently detected.
    let size: Float
}

final class CameraController: NSObject, ObservableObject {
    @Published var hands: [HandPose] = []
    @Published var fingerCount: Int = 0
    @Published var isRecording: Bool = false
    @Published var dieResult: Int?
    @Published var gameMessages: [String] = []
    @Published var debugText: String = ""

    func updateDebugText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.debugText != text else { return }
            self.debugText = text
        }
    }

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
    private var windowRecorder: WindowRecorder?

    func updateOrbSnapshot(_ snap: OrbSnapshot) {
        let newResult = snap.dieResult
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dieResult != newResult else { return }
            self.dieResult = newResult
        }
    }

    func appendGameMessage(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.gameMessages.append(message)
        }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let recorder = try await WindowRecorder.start(
                    windowTitle: "MagicScan",
                    onFrame: { [weak self] sample in
                        self?.videoQueue.async {
                            self?.appendWindowFrame(sample)
                        }
                    }
                )
                self.videoQueue.async { [weak self] in
                    guard let self else { return }
                    if self.assetWriter == nil {
                        guard self.setupAssetWriter(width: recorder.pixelWidth,
                                                    height: recorder.pixelHeight) else {
                            Task { try? await recorder.stop() }
                            return
                        }
                    }
                    self.windowRecorder = recorder
                }
            } catch {
                NSLog("MagicScan: window capture start failed — \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        let recorder = self.windowRecorder
        self.windowRecorder = nil
        if let recorder { Task { try? await recorder.stop() } }

        videoQueue.async { [weak self] in
            guard let self else { return }
            guard let writer = self.assetWriter, let input = self.videoInput else {
                DispatchQueue.main.async { self.isRecording = false }
                return
            }
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

    private func appendWindowFrame(_ sample: CMSampleBuffer) {
        guard let writer = assetWriter, writer.status == .writing,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if recordingStartTime == nil {
            recordingStartTime = pts
            writer.startSession(atSourceTime: pts)
        }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
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
        let preferredChirality = HandPreference.current.chirality
        let newHands = observations
            .filter { $0.chirality == preferredChirality }
            .compactMap { Self.extractPose($0) }
        let newFingerCount = newHands.reduce(0) { acc, h in
            acc + h.fingers.lazy.filter(\.extended).count
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

        var size: Float = 0
        if let idx = pt(.indexMCP), let lit = pt(.littleMCP) {
            size = Float(hypot(idx.x - lit.x, idx.y - lit.y))
        }

        return HandPose(fingers: fingers, palm: palm, roll: roll, size: size)
    }
}

/// Captures the MagicScan main window via ScreenCaptureKit and forwards
/// frames to a callback. Construction is via the async `start` factory so
/// callers receive a fully-running stream with the actual pixel
/// dimensions chosen for the AVAssetWriter.
final class WindowRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    let pixelWidth: Int
    let pixelHeight: Int

    private let stream: SCStream
    private let onFrame: (CMSampleBuffer) -> Void
    private static let outputQueue = DispatchQueue(label: "magicscan.window-recorder")

    private init(stream: SCStream, width: Int, height: Int,
                 onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.stream = stream
        self.pixelWidth = width
        self.pixelHeight = height
        self.onFrame = onFrame
    }

    static func start(windowTitle: String,
                      onFrame: @escaping (CMSampleBuffer) -> Void) async throws -> WindowRecorder {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let bundleID = Bundle.main.bundleIdentifier
        guard let window = content.windows.first(where: { w in
            w.owningApplication?.bundleIdentifier == bundleID && w.title == windowTitle
        }) else {
            throw NSError(domain: "MagicScan.WindowRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Could not find window titled \(windowTitle)"])
        }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        // Round down to even dimensions so H.264 is happy.
        var px = Int(window.frame.width * scale)
        var py = Int(window.frame.height * scale)
        if px % 2 != 0 { px -= 1 }
        if py % 2 != 0 { py -= 1 }

        let cfg = SCStreamConfiguration()
        cfg.width = px
        cfg.height = py
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 5
        cfg.showsCursor = false
        cfg.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        let recorder = WindowRecorder(stream: stream, width: px, height: py, onFrame: onFrame)
        try stream.addStreamOutput(recorder, type: .screen,
                                   sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        return recorder
    }

    func stop() async throws {
        try await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only forward "complete" frames — SCStream also delivers idle/blank
        // status sample buffers with no real pixel data.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        onFrame(sampleBuffer)
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
    @AppStorage(DieKind.storageKey) private var dieKind: String = DieKind.d6.rawValue
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OrbSceneView(camera: camera, hand: camera.hands.first)
            .id(dieKind)
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
            // In Adventure mode the die is embedded in the main window,
            // so the standalone window is redundant. Dismiss any time
            // it would appear (auto-open at launch, manual menu pick,
            // or a mode-switch while open).
            .onAppear {
                if dieKind == DieKind.d20.rawValue {
                    dismissWindow(id: "orb")
                }
            }
            .onChange(of: dieKind) { newValue in
                if newValue == DieKind.d20.rawValue {
                    dismissWindow(id: "orb")
                }
            }
    }
}

/// Compact die-roller embedded in the camera preview during Adventure
/// mode. Same scene as the standalone window, with smaller result text
/// and a rounded frame.
struct EmbeddedOrbView: View {
    @EnvironmentObject var camera: CameraController
    @AppStorage(DieKind.storageKey) private var dieKind: String = DieKind.d6.rawValue

    var body: some View {
        OrbSceneView(camera: camera, hand: camera.hands.first)
            .id(dieKind)
            .background(Color(white: 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                if let result = camera.dieResult {
                    Text("\(result)")
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 8)
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

    /// Build the die geometry for the configured kind. The returned
    /// geometry's per-face material order matches the face-number layout
    /// used by `orientationFor(faceNumber:kind:)`.
    static func makeDieGeometry(kind: DieKind = .current) -> SCNGeometry {
        switch kind {
        case .d6: return makeD6Geometry()
        case .d20: return makeD20Geometry()
        }
    }

    /// Six-faced cube with procedurally-drawn pip face textures laid out
    /// so opposite faces sum to seven (1↔6, 2↔5, 3↔4).
    static func makeD6Geometry() -> SCNGeometry {
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

    /// Find the face whose orientation is closest to the current die
    /// orientation. Used to settle the die to a face when the user
    /// releases without a qualifying throw motion — picks whichever
    /// face is currently most facing the camera.
    static func nearestFace(to orientation: simd_quatf, kind: DieKind = .current) -> Int {
        var bestFace = 1
        var bestDot: Float = -1
        for face in 1...kind.faceCount {
            let target = orientationFor(faceNumber: face, kind: kind)
            // Quaternion dot product; abs picks the shortest path.
            let dot = abs(orientation.real * target.real
                          + simd_dot(orientation.imag, target.imag))
            if dot > bestDot {
                bestDot = dot
                bestFace = face
            }
        }
        return bestFace
    }

    /// Object-space orientation that places the given face number's
    /// normal pointing toward the camera (+Z world). Dispatches by kind.
    static func orientationFor(faceNumber: Int, kind: DieKind = .current) -> simd_quatf {
        switch kind {
        case .d6: return d6Orientation(faceNumber: faceNumber)
        case .d20:
            if let n = d20FaceNormal(for: faceNumber) {
                return simd_quatf(from: n, to: SIMD3<Float>(0, 0, 1))
            }
            return simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        }
    }

    private static func d6Orientation(faceNumber: Int) -> simd_quatf {
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

    /// 20-sided icosahedral die. Each triangular face is its own
    /// sub-element with a number-stamped material; antipodal pairs are
    /// numbered to sum to 21 (1↔20, 2↔19, …, 10↔11).
    static func makeD20Geometry() -> SCNGeometry {
        let layout = d20Layout

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(60)
        normals.reserveCapacity(60)
        uvs.reserveCapacity(60)
        for face in layout.faces {
            let a = layout.vertices[face.indices.0]
            let b = layout.vertices[face.indices.1]
            let c = layout.vertices[face.indices.2]
            positions += [a, b, c]
            normals += [face.normal, face.normal, face.normal]
            // UV winding swapped (v0/v1) so the chirality matches the
            // CCW-from-outside geometry — otherwise the digit textures
            // sample mirrored.
            uvs += [
                SIMD2<Float>(0.94, 0.08),
                SIMD2<Float>(0.06, 0.08),
                SIMD2<Float>(0.50, 0.94),
            ]
        }

        let posData = Data(bytes: positions, count: MemoryLayout<SIMD3<Float>>.stride * positions.count)
        let nrmData = Data(bytes: normals,   count: MemoryLayout<SIMD3<Float>>.stride * normals.count)
        let uvData  = Data(bytes: uvs,       count: MemoryLayout<SIMD2<Float>>.stride * uvs.count)

        let posSrc = SCNGeometrySource(data: posData, semantic: .vertex,
                                        vectorCount: positions.count,
                                        usesFloatComponents: true,
                                        componentsPerVector: 3,
                                        bytesPerComponent: MemoryLayout<Float>.size,
                                        dataOffset: 0,
                                        dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let nrmSrc = SCNGeometrySource(data: nrmData, semantic: .normal,
                                        vectorCount: normals.count,
                                        usesFloatComponents: true,
                                        componentsPerVector: 3,
                                        bytesPerComponent: MemoryLayout<Float>.size,
                                        dataOffset: 0,
                                        dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let uvSrc  = SCNGeometrySource(data: uvData, semantic: .texcoord,
                                        vectorCount: uvs.count,
                                        usesFloatComponents: true,
                                        componentsPerVector: 2,
                                        bytesPerComponent: MemoryLayout<Float>.size,
                                        dataOffset: 0,
                                        dataStride: MemoryLayout<SIMD2<Float>>.stride)

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for (i, face) in layout.faces.enumerated() {
            let indices: [Int32] = [Int32(i*3), Int32(i*3+1), Int32(i*3+2)]
            let data = Data(bytes: indices, count: MemoryLayout<Int32>.size * indices.count)
            let element = SCNGeometryElement(data: data,
                                              primitiveType: .triangles,
                                              primitiveCount: 1,
                                              bytesPerIndex: MemoryLayout<Int32>.size)
            elements.append(element)

            let m = SCNMaterial()
            m.diffuse.contents = makeNumberFaceImage(number: face.number)
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.5
            m.metalness.contents = 0.05
            m.isDoubleSided = true
            materials.append(m)
        }

        let geom = SCNGeometry(sources: [posSrc, nrmSrc, uvSrc], elements: elements)
        geom.materials = materials
        return geom
    }

    struct D20Layout {
        struct Face {
            let indices: (Int, Int, Int)
            let normal: SIMD3<Float>
            let number: Int
        }
        let vertices: [SIMD3<Float>]
        let faces: [Face]
    }

    /// Cached icosahedron vertices + face data with antipodal face
    /// numbers (pairs sum to 21).
    static let d20Layout: D20Layout = {
        let phi: Float = (1 + sqrt(5.0)) / 2
        let raw: [SIMD3<Float>] = [
            SIMD3(-1,  phi,  0), SIMD3( 1,  phi,  0),
            SIMD3(-1, -phi,  0), SIMD3( 1, -phi,  0),
            SIMD3( 0, -1,  phi), SIMD3( 0,  1,  phi),
            SIMD3( 0, -1, -phi), SIMD3( 0,  1, -phi),
            SIMD3( phi, 0, -1), SIMD3( phi, 0,  1),
            SIMD3(-phi, 0, -1), SIMD3(-phi, 0,  1),
        ]
        // Match the d6's corner-to-center distance (√3 · 0.7) so both
        // dice occupy a similar visual volume.
        let circumradius = sqrt(1 + phi * phi)
        let target: Float = 0.7 * sqrt(3)
        let scale = target / circumradius
        let vertices = raw.map { $0 * scale }

        let triples: [(Int, Int, Int)] = [
            (0,11, 5), (0, 5, 1), (0, 1, 7), (0, 7,10), (0,10,11),
            (1, 5, 9), (5,11, 4), (11,10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4,11), (6, 2,10), (8, 6, 7), (9, 8, 1),
        ]
        let normals: [SIMD3<Float>] = triples.map {
            let c = (vertices[$0.0] + vertices[$0.1] + vertices[$0.2]) / 3
            return simd_normalize(c)
        }

        var number = [Int](repeating: 0, count: 20)
        var assigned = [Bool](repeating: false, count: 20)
        var nextLow = 1
        for i in 0..<20 where !assigned[i] {
            var bestJ = -1
            var bestDot: Float = 2
            for j in 0..<20 where !assigned[j] && j != i {
                let d = simd_dot(normals[i], normals[j])
                if d < bestDot { bestDot = d; bestJ = j }
            }
            number[i] = nextLow
            number[bestJ] = 21 - nextLow
            assigned[i] = true
            assigned[bestJ] = true
            nextLow += 1
        }

        let faces = triples.enumerated().map { i, t in
            D20Layout.Face(indices: t, normal: normals[i], number: number[i])
        }
        return D20Layout(vertices: vertices, faces: faces)
    }()

    static func d20FaceNormal(for number: Int) -> SIMD3<Float>? {
        d20Layout.faces.first(where: { $0.number == number })?.normal
    }

    /// Dark-background number face used for the D20. Adds an underline
    /// to 6/9 to disambiguate when read from above. Numbers are sized to
    /// fit inside the triangular UV region's inscribed circle.
    static func makeNumberFaceImage(number: Int) -> NSImage {
        let size: CGFloat = 256
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.32, alpha: 1).set()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .heavy),
            .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.78, alpha: 1),
        ]
        if number == 6 || number == 9 {
            attrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            attrs[.underlineColor] = NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.78, alpha: 1)
        }
        let s = NSAttributedString(string: "\(number)", attributes: attrs)
        let bounds = s.size()
        // The UV triangle's centroid is at (0.5, 0.367) where y=0 is the
        // wide base. NSImage lockFocus draws bottom-up, but SceneKit
        // samples the texture with UV (0,0) at top-left, so we flip y to
        // land the glyph at the actual centroid of the rendered face.
        // The -bounds.height*0.18 nudge accounts for line-leading above
        // the cap so the digit's optical center sits on the centroid.
        let cx = size * 0.5
        let cy = size * (1 - 0.367)
        s.draw(at: NSPoint(x: cx - bounds.width / 2,
                            y: cy - bounds.height / 2 - bounds.height * 0.18))

        image.unlockFocus()
        return image
    }

    enum DieState {
        case tracking   // die orientation slerps toward hand roll
        case spinning   // angular velocity decays to rest
        case settled    // showing a result, waits for next grip
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        // Append-only debug log written to ~/Movies/MagicScan/throw-debug.log.
        // Reset on first frame so each run is a clean trace.
        private static let debugLogQueue = DispatchQueue(label: "magicscan.debug.log")
        private static let debugLogURL: URL = {
            let movies = FileManager.default
                .urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let dir = movies.appendingPathComponent("MagicScan", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("throw-debug.log")
        }()

        static func debugLog(_ line: String) {
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
            let full = "[\(stamp)] \(line)\n"
            debugLogQueue.async {
                guard let data = full.data(using: .utf8) else { return }
                let url = debugLogURL
                if FileManager.default.fileExists(atPath: url.path),
                   let h = try? FileHandle(forWritingTo: url) {
                    try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                    try? h.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }

        static func resetDebugLog() {
            debugLogQueue.async {
                try? FileManager.default.removeItem(at: debugLogURL)
            }
        }

        /// Pick a random face number from the current die kind that is
        /// NOT the given face. Guarantees the visual roll always lands
        /// on a different face than the one currently up, so even slow
        /// throws produce a clear "the die changed" moment.
        static func randomFaceExcluding(_ excluded: Int) -> Int {
            let count = DieKind.current.faceCount
            guard count > 1 else { return 1 }
            var pick = Int.random(in: 1..<count)  // 1...count-1
            if pick >= excluded { pick += 1 }      // skip the excluded slot
            return pick
        }

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

        // Throw detection. `wasGripped` latches when the hand crosses
        // the grip threshold; `gripStartSize` anchors the knuckle span
        // at that moment so the throw decision can compare absolute
        // forward displacement (grew since grip) rather than an
        // instantaneous velocity, which was prone to firing on wind-up
        // jitter.
        private var wasGripped: Bool = false
        private var gripStartSize: Float = 0
        private var peakSpeed: Float = 0
        private var smoothedSize: Float = 0
        private var prevPalm = SIMD2<Float>(0.5, 0.5)
        private var lastTime: TimeInterval = 0
        private var frameCounter: Int = 0
        // Counts consecutive frames where totalPress is above the grip
        // threshold. wasGripped only latches after a sustained run, so
        // brief detection blips when the hand enters frame don't get
        // mistaken for a deliberate grip-release.
        private var gripStableFrames: Int = 0
        // 3-sample buffer for palm-speed median filter. Vision joint
        // estimates can teleport when the wrist flexes far enough that
        // MCPs partially disappear, producing single-frame palm-speed
        // spikes of 10+/sec that aren't real motion. Median(3) rejects
        // any single-frame spike — sustained motion (real throws) gets
        // through unchanged because at least 2 of 3 samples are high.
        private var recentPalmSpeeds: [Float] = []

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            if lastTime == 0 {
                Self.resetDebugLog()
                Self.debugLog("--- new run, sensitivity=\(ThrowSensitivity.current.rawValue) thresh=\(ThrowSensitivity.current.forwardThreshold) ---")
            }
            let dt = lastTime > 0 ? Float(min(0.05, time - lastTime)) : 1.0 / 60.0
            lastTime = time

            var targetTips = Array(repeating: SIMD2<Float>(0.5, 0.5), count: 5)
            var targetStrengths: [Float] = [0, 0, 0, 0, 0]
            var targetRoll: Float = 0
            var targetSize: Float = smoothedSize
            let presenceTarget: Float = (targetHand != nil) ? 1 : 0
            if let hand = targetHand {
                for (i, f) in hand.fingers.prefix(5).enumerated() {
                    if let tip = f.joints.last {
                        targetTips[i] = SIMD2(Float(tip.x), Float(tip.y))
                    }
                    targetStrengths[i] = f.pressStrength
                }
                targetRoll = hand.roll ?? 0
                if hand.size > 0 { targetSize = hand.size }
            }

            for i in 0..<5 {
                smoothedTips[i] += (targetTips[i] - smoothedTips[i]) * 0.6
                smoothedStrengths[i] += (targetStrengths[i] - smoothedStrengths[i]) * 0.5
            }
            smoothedRoll += (targetRoll - smoothedRoll) * 0.3
            smoothedPresence += (presenceTarget - smoothedPresence) * 0.2
            smoothedSize += (targetSize - smoothedSize) * 0.4

            let totalPress = smoothedStrengths.reduce(0, +)
            let palm = (smoothedTips.reduce(SIMD2<Float>.zero, +)) / 5
            let palmDelta = palm - prevPalm
            let palmSpeed = sqrt(palmDelta.x * palmDelta.x + palmDelta.y * palmDelta.y) / max(dt, 1e-3)

            // Median-filter palmSpeed over a 3-frame window before
            // feeding it into peakSpeed — kills single-frame Vision
            // teleports without dampening real sustained motion.
            recentPalmSpeeds.append(palmSpeed)
            if recentPalmSpeeds.count > 3 { recentPalmSpeeds.removeFirst() }
            let medianPalmSpeed: Float = {
                let sorted = recentPalmSpeeds.sorted()
                return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            }()

            // Decay the palm-speed peak ~8%/frame so a high value sticks
            // around for ~1 second after the moment we saw it. Used to
            // size the spin once a throw fires, since by the time we
            // detect "enough forward displacement" the hand may already
            // be slowing.
            peakSpeed = max(peakSpeed * 0.92, medianPalmSpeed)

            switch dieState {
            case .tracking:
                // Only let the die track hand roll once a real grip
                // has latched. Otherwise an ungripped hand passing
                // through frame visibly wobbles the die — fine for a
                // 20-face icosahedron whose geometry is uniform, but
                // a cube broadcasts every rotation and reads as
                // "the die got hit."
                if wasGripped {
                    let target = simd_quatf(angle: -smoothedRoll, axis: SIMD3<Float>(0, 0, 1))
                    dieOrientation = simd_slerp(dieOrientation, target,
                                                 min(1, dt * 8))
                }

                // Track sustained grip: only latch wasGripped after the
                // grip threshold has been crossed for ~100ms. Brief
                // hand-enters-frame blips (where smoothing transiently
                // pushes totalPress > 1.2 for 1-2 frames) don't count.
                if totalPress > 1.2 {
                    gripStableFrames += 1
                } else {
                    gripStableFrames = 0
                }
                let prevGripped = wasGripped
                if gripStableFrames >= 6 { wasGripped = true }  // ~100ms at 60fps
                if !prevGripped && wasGripped {
                    gripStartSize = smoothedSize
                    peakSpeed = 0
                    Self.debugLog(String(format: "GRIP_LATCH press=%.2f size=%.4f stableFrames=\(gripStableFrames)",
                                         totalPress, smoothedSize))
                }

                // Two independent fire paths:
                //   Path A — slow deliberate throw: knuckle-span grew
                //   forward by an absolute amount, and the hand was at
                //   least moving (peakSpd > 0.5 rejects pure jitter).
                //   Path B — fast lateral or off-screen throw: peak
                //   palm speed crossed a high threshold while the hand
                //   wasn't notably moving backward. This catches the
                //   cases where the hand exits frame or rotates such
                //   that knuckle span barely changes.
                // A pull-back wind-up has notably negative growth and
                // is rejected by both paths.
                let growthThreshold = ThrowSensitivity.current.forwardThreshold
                let speedThreshold  = ThrowSensitivity.current.peakSpeedThreshold
                let forwardGrowth   = smoothedSize - gripStartSize
                let pathA = forwardGrowth > growthThreshold && peakSpeed > 0.5
                let pathB = peakSpeed > speedThreshold && forwardGrowth > -0.005

                if wasGripped && (pathA || pathB) {
                    // Use the median-filtered palm speed for the spin
                    // amount too — otherwise a single-frame Vision
                    // teleport at the fire instant overshoots the cap
                    // and produces a faster spin than the real motion.
                    let throwSpeed = max(medianPalmSpeed, peakSpeed)
                    // Total visible rotation ≈ speed / decay. With
                    // base 35 and decay 2.2 a baseline throw lands
                    // ~2.5 rotations; fast throws (peakSpd 5+) push
                    // toward 4-6 rotations before the cap.
                    let baseSpeed: Float = 35
                    let speed = max(baseSpeed, min(80, throwSpeed * 14))
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
                    rolledFace = Self.randomFaceExcluding(
                        OrbSceneView.nearestFace(to: dieOrientation))
                    dieResult = nil
                    dieState = .spinning
                    let firePath = pathA ? "A_growth" : "B_speed"
                    Self.debugLog(String(format: "FIRE path=\(firePath) growth=%.4f peakSpd=%.2f throwSpd=%.2f",
                                         forwardGrowth, peakSpeed, throwSpeed))
                    wasGripped = false
                    peakSpeed = 0
                    camera?.appendGameMessage("YOU ROLLED THE DIE")
                } else if wasGripped && totalPress < 0.5 {
                    // Released without a qualifying throw — gentle
                    // roll: pick a random face and quickly tumble to
                    // it. Lower starting angular velocity so the spin
                    // visibly differs from a "real" thrown roll, but
                    // still produces a fresh result every grip-release.
                    let face = Self.randomFaceExcluding(
                        OrbSceneView.nearestFace(to: dieOrientation))
                    let tumble = SIMD3<Float>(
                        Float.random(in: -1...1),
                        Float.random(in: -1...1),
                        Float.random(in: -0.4...0.4)
                    )
                    let tlen = sqrt(tumble.x * tumble.x + tumble.y * tumble.y + tumble.z * tumble.z)
                    let axis = tlen > 0.001 ? tumble / tlen : SIMD3<Float>(1, 0, 0)
                    angularVelocity = axis * 24
                    rolledFace = face
                    dieResult = nil
                    dieState = .spinning
                    let reason = (smoothedPresence < 0.5) ? "exited_frame" : "opened_hand"
                    Self.debugLog(String(format: "SETTLE reason=\(reason) growth=%.4f peakSpd=%.2f face=\(face)",
                                         forwardGrowth, peakSpeed))
                    camera?.appendGameMessage("YOU ROLLED THE DIE")
                    wasGripped = false
                    peakSpeed = 0
                } else if wasGripped && frameCounter % 3 == 0 {
                    // Heartbeat while gripped — captures the actual
                    // motion timeline so we can see why a throw didn't
                    // fire.
                    Self.debugLog(String(
                        format: "GRIP press=%.2f size=%.4f growth=%+.4f/%.3f palmSpd=%.2f peakSpd=%.2f pres=%.2f",
                        totalPress, smoothedSize, forwardGrowth, growthThreshold,
                        palmSpeed, peakSpeed, smoothedPresence
                    ))
                }
            case .spinning:
                let speed = sqrt(angularVelocity.x * angularVelocity.x
                                 + angularVelocity.y * angularVelocity.y
                                 + angularVelocity.z * angularVelocity.z)
                if speed > 0.5 {
                    let axis = angularVelocity / speed
                    let dq = simd_quatf(angle: speed * dt, axis: axis)
                    dieOrientation = simd_mul(dq, dieOrientation)
                    angularVelocity *= exp(-2.2 * dt)

                    // Below ~3 rad/s, blend toward the pre-picked target
                    // orientation so the spin glides smoothly into the
                    // chosen face without a visible snap.
                    if let face = rolledFace, speed < 3 {
                        let target = OrbSceneView.orientationFor(faceNumber: face)
                        let approach = (3 - speed) / 3
                        let step = min(1, approach * dt * 6)
                        dieOrientation = simd_slerp(dieOrientation, target, step)
                    }
                } else {
                    if let face = rolledFace {
                        dieOrientation = OrbSceneView.orientationFor(faceNumber: face)
                        dieResult = face
                        camera?.appendGameMessage("YOU ROLLED A \(face)")
                    }
                    rolledFace = nil
                    angularVelocity = .zero
                    dieState = .settled
                }
            case .settled:
                if totalPress > 1.2 {
                    dieResult = nil
                    dieState = .tracking
                    wasGripped = false
                    peakSpeed = 0
                    gripStableFrames = 0
                }
            }

            prevPalm = palm
            frameCounter += 1

            // Publish a live debug readout to the camera-view HUD every
            // 4 frames (~15 Hz) — fast enough to feel live, slow enough
            // to keep the UI cheap.
            if frameCounter % 4 == 0 {
                let growthThreshold = ThrowSensitivity.current.forwardThreshold
                let forwardGrowth = smoothedSize - gripStartSize
                let stateName: String = {
                    switch dieState {
                    case .tracking: return "track"
                    case .spinning: return "spin"
                    case .settled:  return "settle"
                    }
                }()
                let dbg = String(
                    format: """
                    state:  %@
                    grip:   %@   press: %.2f
                    size:   %.4f   start: %.4f
                    growth: %+.4f / %.3f
                    palm:   %.2f   peak: %.2f / 0.50
                    pres:   %.2f
                    """,
                    stateName,
                    wasGripped ? "Y" : "N", totalPress,
                    smoothedSize, gripStartSize,
                    forwardGrowth, growthThreshold,
                    palmSpeed, peakSpeed,
                    smoothedPresence
                )
                camera?.updateDebugText(dbg)
            }

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
