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
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button(camera.isRecording ? "Stop Recording" : "Start Recording") {
                    camera.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                // Debug: spawn a standalone hack session, no battle
                // required. ContentView treats the outcome as a no-op
                // log when not in battle, so you can chain runs.
                Button("Open Hack Terminal (Debug)") {
                    camera.hackTestRequest &+= 1
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        Window("Die Roller", id: "orb") {
            OrbView()
                .environmentObject(camera)
                .frame(minWidth: 320, minHeight: 320)
        }
        .defaultSize(width: 480, height: 480)
        // Without this, AppKit auto-opens the Die Roller window at
        // launch. In Adventure mode OrbView dismisses itself in
        // onAppear, but the OrbSceneView's Coordinator has already
        // spun up by then and stays alive in parallel with the
        // EmbeddedOrbView's Coordinator — every throw fires twice
        // with two different face numbers. Suppressing the auto-open
        // means the window only exists when openWindow is called
        // (Casino mode), so there's exactly one live Coordinator.
        .defaultLaunchBehavior(.suppressed)

        // Hack minigame terminal. Opened when the player picks Hack
        // from the battle menu; HackView writes the outcome to
        // `camera.hackOutcome` which ContentView watches to apply
        // damage (success) or trigger a free enemy hit (failure).
        // Suppressed at launch so it only exists when summoned.
        Window("Hack Terminal", id: "hack") {
            HackView()
                .environmentObject(camera)
        }
        .defaultSize(width: 580, height: 460)
        .defaultLaunchBehavior(.suppressed)

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

enum AdventureControls: String, CaseIterable, Identifiable {
    case click, arrows
    var id: String { rawValue }
    var label: String {
        switch self {
        case .click:  return "Click to move"
        case .arrows: return "Arrow keys"
        }
    }
    static let storageKey = "adventureControls"
    static var current: AdventureControls {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return AdventureControls(rawValue: raw) ?? .click
    }
}

struct SettingsView: View {
    @AppStorage(HandPreference.storageKey) private var preferred: String = HandPreference.right.rawValue
    @AppStorage(DieKind.storageKey) private var die: String = DieKind.d6.rawValue
    @AppStorage(ThrowSensitivity.storageKey) private var sensitivity: String = ThrowSensitivity.normal.rawValue
    @AppStorage(AdventureControls.storageKey) private var controls: String = AdventureControls.click.rawValue

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

            Picker("Adventure controls", selection: $controls) {
                ForEach(AdventureControls.allCases) { c in
                    Text(c.label).tag(c.rawValue)
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
    @AppStorage(AdventureControls.storageKey) private var adventureControls: String = AdventureControls.click.rawValue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Story-floor cap. The bottom of the dungeon — descent attempts
    /// past this floor get refused. Sized to leave plenty of headroom
    /// under the memory ceiling (~150 MB if every floor were cached).
    private static let maxFloor = 100_000
    /// DEMO: descending through floor 5's door ends the run with the
    /// win screen instead of generating floor 6. Temporary — remove
    /// when the full progression is wired.
    private static let demoFinalFloor = 5
    @State private var dungeonMap = DungeonMap.make(floor: 1)
    /// Combat state. Stats follow the locked 1-20 range; the damage
    /// formula `max(1, attacker.str + d20 - defender.physDef)` drives
    /// Fight. Player combat stats start at 1 to create headroom for
    /// progression once items/leveling exist. HP and MP stay higher
    /// so the early game isn't a one-hit ordeal.
    @State private var playerStats: Stats = Stats(
        hp: 20, maxHP: 20, mp: 10, maxMP: 10,
        str: 1, spd: 1, physDef: 1, mag: 1, magDef: 1)
    @State private var enemyStats: Stats = EnemyType.shade.baselineStats(floor: 1)
    @State private var currentEnemyType: EnemyType = .shade
    private var enemyName: String { currentEnemyType.displayName }
    /// True while a battle "event" is in progress. Stepping onto an
    /// enemy tile sets this; it stays true until the player flees
    /// successfully (Fight isn't wired yet). Map controls
    /// (arrow-keys, click-to-move, stairs) are all blocked while it's
    /// true so the player can't just walk away from the encounter.
    @State private var inBattle: Bool = false
    /// Index into `battleMenuOptions`. Driven by ↑/↓ during battle.
    @State private var battleMenuIndex: Int = 0
    /// What action the next die roll resolves, or nil if no roll is
    /// pending. Set when the player confirms a menu option that needs
    /// a roll (Fight or Flee); cleared as soon as `dieResult` settles
    /// and `handleRollResult` consumes it.
    @State private var pendingRoll: PendingRoll? = nil
    private var awaitingRoll: Bool { pendingRoll != nil }
    /// True between "the d20 settled" and "battle resolves." Gives
    /// the player a beat to actually see the rolled face before the
    /// fight view fades. All battle inputs are inert during this
    /// window so a stray key can't kick off a second shake.
    @State private var resolvingRoll: Bool = false
    /// How long the settled die stays on screen post-roll. Long
    /// enough to read the face; short enough not to feel sluggish.
    private static let postRollHoldSeconds: Double = 1.5
    /// Set when the fight-start transition (pixel shatter + ENGAGE
    /// flash) is playing. Non-nil = transition in progress. All
    /// inputs are blocked during the window so the player can't act
    /// on a UI they can't see.
    @State private var fightTransitionStart: Date? = nil
    /// Set the moment damage lands (not on whiffs). Drives the white
    /// flash overlay + screen shake for ~0.3s, then clears itself.
    @State private var hitImpactStart: Date? = nil
    /// Set the moment an enemy's HP drops to 0. FightView3D watches
    /// this to play the wireframe explosion before the fight view
    /// fades out.
    @State private var defeatedEnemyAt: Date? = nil
    /// Bumped each time the enemy takes its turn. FightView3D watches
    /// the new timestamp and runs the eye-glow windup + laser beam
    /// animation. Damage and hit-impact are scheduled separately so
    /// they land in sync with the beam fire.
    @State private var enemyAttackAt: Date? = nil
    /// Set the moment the laser visually lands. Drives the red
    /// full-screen flash overlay + heavier shake — distinct from the
    /// player's white hit-flash so the two reads don't clash.
    @State private var enemyHitImpactStart: Date? = nil
    /// True if the shade has already had its turn in the current
    /// round. Speed gives one combatant initiative; whoever moves
    /// first uses up that round's turn budget. Cleared the moment the
    /// player picks a new action.
    @State private var enemyActedThisRound: Bool = false
    /// Hack charges remaining in the current battle. Base 1, plus one
    /// per equipped piece carrying the `.extraHack` special. Reset at
    /// `startBattle`, decremented by `handleHackOutcome`. Drives the
    /// Hack menu's enabled flag.
    @State private var hackChargesRemaining: Int = 0
    /// Set the moment the player's HP hits 0. Drives the GAME OVER
    /// shatter outro; nil = normal play. SPACE while non-nil runs
    /// `restartFromGameOver`. All other input is blocked.
    @State private var gameOverStart: Date? = nil
    /// DEMO: set when the player clears floor 5's door. Drives the
    /// win-screen outro; nil = normal play. SPACE while non-nil runs
    /// `restartFromWin`. Gated like `gameOverStart`.
    @State private var winStart: Date? = nil
    /// Unequipped gear carried this run. Capped at `backpackCap` so
    /// "what do I drop?" stays a live decision. Wiped on any restart
    /// (heirloom carry-over is a deferred follow-up).
    @State private var backpack: [GearItem] = []
    /// The three equip slots. Stat bumps from equipped items fold into
    /// `effectivePlayerStats`; specials are read directly in combat.
    @State private var equipped: [GearSlot: GearItem] = [:]
    private static let backpackCap = 6
    /// Inventory/equip overlay (dungeon, out of combat). `invIndex`
    /// walks a flat list: the 3 slot rows, then each backpack item.
    @State private var inventoryOpen = false
    @State private var invIndex = 0

    /// Flat selectable rows for the inventory cursor: the three slots
    /// in fixed order, then the backpack items.
    private var invSlotOrder: [GearSlot] { [.weapon, .armor, .trinket] }
    private var invRowCount: Int { invSlotOrder.count + backpack.count }

    private func invMove(_ delta: Int) {
        guard invRowCount > 0 else { invIndex = 0; return }
        invIndex = (invIndex + delta % invRowCount + invRowCount) % invRowCount
    }

    /// Return on a slot row unequips it; on a backpack row equips it.
    private func invActivate() {
        let slots = invSlotOrder
        if invIndex < slots.count {
            unequip(slots[invIndex])
        } else {
            let i = invIndex - slots.count
            if backpack.indices.contains(i) { equip(backpack[i]) }
        }
        invIndex = min(invIndex, max(0, invRowCount - 1))
    }

    private func invDiscard() {
        let i = invIndex - invSlotOrder.count
        guard backpack.indices.contains(i) else { return }
        discard(backpack[i])
        invIndex = min(invIndex, max(0, invRowCount - 1))
    }

    private func toggleInventory() {
        guard !inBattle, gameOverStart == nil, winStart == nil,
              fightTransitionStart == nil else { return }
        inventoryOpen.toggle()
        invIndex = 0
        keyboardFocused = true
    }

    /// Base stats + every equipped item's bumps, clamped to the locked
    /// 1-20 design range (HP/MP caps may exceed 20 — they're pools,
    /// not the d-roll-dominated combat stats). Combat reads THIS, not
    /// `playerStats`; `playerStats.hp/.mp` stay the live current pools
    /// and are mutated directly by damage.
    private var effectivePlayerStats: Stats {
        var s = playerStats
        for it in equipped.values {
            s.str += it.dStr; s.spd += it.dSpd
            s.physDef += it.dPhysDef; s.mag += it.dMag; s.magDef += it.dMagDef
            s.maxHP += it.dMaxHP; s.maxMP += it.dMaxMP
        }
        func clamp(_ v: Int) -> Int { max(1, min(20, v)) }
        s.str = clamp(s.str); s.spd = clamp(s.spd)
        s.physDef = clamp(s.physDef); s.mag = clamp(s.mag); s.magDef = clamp(s.magDef)
        s.maxHP = max(1, s.maxHP); s.maxMP = max(0, s.maxMP)
        s.hp = min(s.hp, s.maxHP); s.mp = min(s.mp, s.maxMP)
        return s
    }

    /// Special on the equipped trinket/weapon/armor, if any. Combat
    /// queries these by case.
    private func hasSpecial(_ sp: GearSpecial) -> Bool {
        equipped.values.contains { $0.special == sp }
    }
    /// Increments each time a new battle starts. FightView3D uses
    /// this as a reset signal so a previous battle's exploded enemy
    /// snaps back to full scale/opacity before the next battle's
    /// pixel-shatter transition lifts.
    @State private var battleEpoch: Int = 0
    /// Every floor the player has ever visited, keyed by floor
    /// number. On any stairs transition we save the current map into
    /// the cache and restore the target floor if it's there, so
    /// re-entering a floor brings back its exact layout, reveal
    /// state, and player position. The active floor lives in
    /// `dungeonMap`; the cache holds everything else.
    @State private var floorsByNumber: [Int: DungeonMap] = [:]
    @State private var shakingDie = false
    /// Timestamp of the last arrow-driven action. Used to throttle
    /// key-repeat events when the user holds an arrow, so movement
    /// has a "discrete step" feel instead of ripping through the
    /// dungeon at the OS's key-repeat rate.
    @State private var lastArrowFire: Date = .distantPast
    /// Minimum time between auto-repeat arrow actions. Initial taps
    /// (`.down` phase) bypass this; only `.repeat` events get gated.
    private let arrowRepeatCooldown: TimeInterval = 0.25
    @FocusState private var keyboardFocused: Bool

    private var arrowMode: Bool {
        dieKind == DieKind.d20.rawValue
            && adventureControls == AdventureControls.arrows.rawValue
    }

    /// True iff the player is standing on an enemy tile. The embedded
    /// die only appears in this state — combat is the only thing you
    /// roll for in Adventure mode right now.
    private var isOnEnemyTile: Bool {
        let r = dungeonMap.playerRow, c = dungeonMap.playerCol
        return dungeonMap.tiles[r][c].kind == .enemy
    }

    /// Fires on any move that changes the player's tile (including
    /// floor changes via stairs). Used as the trigger for entering a
    /// battle so direct enemy-to-enemy steps don't get skipped.
    private var playerPositionKey: String {
        "\(dungeonMap.floor)/\(dungeonMap.playerRow),\(dungeonMap.playerCol)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if dieKind == DieKind.d20.rawValue {
                HStack(spacing: 0) {
                    dungeonView3D()
                    DungeonMapView(map: $dungeonMap,
                                   onStairs: { useStairs() },
                                   disabled: inBattle,
                                   log: { camera.appendGameMessage($0) },
                                   onChest: { openChestHere() })
                }
                GameTextBox(messages: camera.gameMessages)
            } else {
                cameraPreview()
            }
        }
        .overlay {
            // Game Over outro — full-window so it covers the 3D pane,
            // the 2D map, and the text log (paired with the win
            // screen). Non-interactive: SPACE restart is handled by
            // the existing key path, gated on `gameOverStart`.
            if let started = gameOverStart {
                GameOverView(startedAt: started)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // DEMO win screen — full-window, same treatment as Game
            // Over. Non-interactive: SPACE is handled by the existing
            // key path, gated on `winStart`.
            if let started = winStart {
                WinView(startedAt: started,
                        items: backpack + Array(equipped.values))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // Inventory / equip menu — dungeon, out of combat.
            // Keyboard-driven (gated via `inventoryOpen`); the dimmer
            // takes hits so the map behind doesn't react to clicks.
            if inventoryOpen {
                InventoryView(slotOrder: invSlotOrder,
                              equipped: equipped,
                              backpack: backpack,
                              selection: invIndex,
                              base: playerStats,
                              effective: effectivePlayerStats,
                              cap: Self.backpackCap)
            }
        }
        .focusable(arrowMode || inBattle || inventoryOpen)
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress(.upArrow,    phases: [.down, .repeat]) { handleArrow(.up,    phase: $0.phase) }
        .onKeyPress(.downArrow,  phases: [.down, .repeat]) { handleArrow(.down,  phase: $0.phase) }
        .onKeyPress(.leftArrow,  phases: [.down, .repeat]) { handleArrow(.left,  phase: $0.phase) }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { handleArrow(.right, phase: $0.phase) }
        .onKeyPress(.space, phases: [.down, .up]) { handleSpace($0.phase) }
        .onKeyPress(.return)     { handleInteract() }
        .onKeyPress(KeyEquivalent("i")) { toggleInventory(); return .handled }
        .onKeyPress(KeyEquivalent("x")) {
            if inventoryOpen { invDiscard(); return .handled }
            return .ignored
        }
        .onChange(of: playerPositionKey) { _ in
            // Drop shake state if we leave the tile mid-press.
            if !isOnEnemyTile { shakingDie = false }
            // Triggering on the position key (not on isOnEnemyTile)
            // catches the case where a successful flee leaves the
            // player on an enemy tile and they then step *directly*
            // to an adjacent enemy — isOnEnemyTile stays true so an
            // onChange watcher on it wouldn't fire.
            if isOnEnemyTile && !inBattle && fightTransitionStart == nil {
                startBattle()
            }
        }
        .onChange(of: camera.dieResult) { newValue in
            // When the die settles and we have a pending roll (Fight
            // or Flee), apply the outcome. Other rolls are ignored.
            guard let result = newValue, awaitingRoll else { return }
            handleRollResult(result)
        }
        .onChange(of: camera.hackOutcome) { newValue in
            // HackView posts here when its session ends (timeout or
            // detonate). Clear right away so a follow-up hack with
            // the same outcome re-fires. When not in battle this is
            // a debug run from Cmd+Shift+H — log and bail without
            // mutating combat state.
            guard let outcome = newValue else { return }
            camera.hackOutcome = nil
            if inBattle {
                handleHackOutcome(outcome)
            } else {
                dismissWindow(id: "hack")
                switch outcome {
                case .success(let score):
                    camera.appendGameMessage("[debug] hack success — score \(score)")
                case .failure:
                    camera.appendGameMessage("[debug] hack failure")
                }
            }
        }
        .onChange(of: camera.hackTestRequest) { _ in
            // Debug entry point — opens the terminal standalone so
            // the puzzle can be iterated without battling through to
            // an enemy. Outcome handler above no-ops when !inBattle.
            openWindow(id: "hack")
        }
        .onAppear {
            // The camera is acquired by individual views that need it
            // (CameraPreview / OrbView / EmbeddedOrbView) — no global
            // startup here, so the camera stays off until the
            // die-roll screen actually appears.
            if dieKind == DieKind.d6.rawValue {
                openWindow(id: "orb")
            }
            if arrowMode { keyboardFocused = true }
        }
        .onChange(of: dieKind) { newValue in
            if newValue == DieKind.d20.rawValue {
                dismissWindow(id: "orb")
                if arrowMode { keyboardFocused = true }
            } else {
                openWindow(id: "orb")
            }
        }
        .onChange(of: adventureControls) { _ in
            if arrowMode { keyboardFocused = true }
        }
    }

    private enum ArrowDir { case up, down, left, right }

    private func handleArrow(_ dir: ArrowDir, phase: KeyPress.Phases) -> KeyPress.Result {
        // Block all input while the fight-start transition is playing
        // or the Game Over screen is up.
        if fightTransitionStart != nil { return .handled }
        if gameOverStart != nil { return .handled }
        if winStart != nil { return .handled }
        // Inventory open: up/down move the cursor, nothing reaches the
        // map. Discrete .down only so a held key doesn't race.
        if inventoryOpen {
            guard phase.contains(.down) else { return .handled }
            switch dir {
            case .up:    invMove(-1)
            case .down:  invMove(1)
            case .left, .right: break
            }
            return .handled
        }
        // While a battle event is running, arrows drive the menu
        // instead of the map. Left/right have no menu meaning yet, so
        // they no-op. During an active die-roll (awaitingRoll) or its
        // resolve hold, all arrows are inert so they can't accidentally
        // cancel the roll.
        if inBattle {
            guard phase.contains(.down) else { return .handled }
            if awaitingRoll || resolvingRoll { return .handled }
            switch dir {
            case .up:
                battleMenuIndex = (battleMenuIndex + battleMenuOptions.count - 1)
                    % battleMenuOptions.count
            case .down:
                battleMenuIndex = (battleMenuIndex + 1) % battleMenuOptions.count
            case .left, .right:
                break
            }
            return .handled
        }
        guard arrowMode else { return .ignored }
        // Key-repeat events get throttled so holding doesn't rip
        // through the map; discrete taps (.down) always fire.
        let now = Date()
        if phase.contains(.repeat),
           now.timeIntervalSince(lastArrowFire) < arrowRepeatCooldown {
            return .handled
        }
        lastArrowFire = now
        switch dir {
        case .up:    logStep(dungeonMap.step(forward: true))
        case .down:  logStep(dungeonMap.step(forward: false))
        case .left:  dungeonMap.turn(by: -1)
        case .right: dungeonMap.turn(by: 1)
        }
        return .handled
    }

    private func handleInteract() -> KeyPress.Result {
        if fightTransitionStart != nil { return .handled }
        if gameOverStart != nil { return .handled }
        if winStart != nil { return .handled }
        if inventoryOpen { invActivate(); return .handled }
        if inBattle && resolvingRoll { return .handled }
        if inBattle && !awaitingRoll {
            confirmMenuSelection()
            return .handled
        }
        guard arrowMode else { return .ignored }
        // Standing on an un-opened chest: interact opens it (opt-in).
        // Otherwise fall through to stair use.
        let r = dungeonMap.playerRow, c = dungeonMap.playerCol
        if dungeonMap.tiles[r][c].kind == .chest {
            openChestHere()
            return .handled
        }
        return useStairs() ? .handled : .ignored
    }

    /// If the player is standing on a stairs tile, take it. Returns
    /// true iff a floor transition happened (so callers can report
    /// the event consumed). Shared by keyboard (`handleInteract`) and
    /// 2D click ("re-click your own tile") so both modes route
    /// through the same cache logic.
    @discardableResult
    private func useStairs() -> Bool {
        // Stairs are inert during a battle event — the player has to
        // resolve the encounter before moving floors.
        guard !inBattle else { return false }
        let r = dungeonMap.playerRow, c = dungeonMap.playerCol
        switch dungeonMap.tiles[r][c].kind {
        case .door, .lockedDoor:
            if dungeonMap.tiles[r][c].kind == .lockedDoor {
                guard dungeonMap.hasKey else {
                    camera.appendGameMessage(Lexicon.gateSealed())
                    return true
                }
                camera.appendGameMessage(Lexicon.keyFits())
            }
            // DEMO: clearing the final floor's door ends the run with
            // the win screen rather than descending further.
            if dungeonMap.floor >= Self.demoFinalFloor {
                triggerWin()
                return true
            }
            let next = dungeonMap.floor + 1
            guard next <= Self.maxFloor else {
                camera.appendGameMessage(Lexicon.worldEnds())
                return true
            }
            floorsByNumber[dungeonMap.floor] = dungeonMap
            if let saved = floorsByNumber[next] {
                dungeonMap = saved
            } else {
                dungeonMap = DungeonMap.make(floor: next,
                                             spawn: (r, c),
                                             spawnIsStairsUp: true)
            }
            camera.appendGameMessage(Lexicon.descend(to: dungeonMap.floor))
            return true
        case .stairsUp:
            let prev = dungeonMap.floor - 1
            guard prev >= 1, let saved = floorsByNumber[prev] else { return false }
            floorsByNumber[dungeonMap.floor] = dungeonMap
            dungeonMap = saved
            camera.appendGameMessage(Lexicon.ascend(to: dungeonMap.floor))
            return true
        default:
            return false
        }
    }

    /// Spacebar's jobs (in priority order):
    ///   1. In the flee-roll sub-phase: hold to shake, release to throw.
    ///   2. In the battle menu (pre-roll): confirms the selected option.
    ///   3. Otherwise: arrow-mode descend on doors / ascend on stairs-up.
    /// Always clears `shakingDie` on .up so a release in the wrong
    /// phase can't leave the die stuck mid-shake.
    private func handleSpace(_ phase: KeyPress.Phases) -> KeyPress.Result {
        if fightTransitionStart != nil { return .handled }
        if gameOverStart != nil {
            // Only SPACE-down restarts; SPACE-up no-ops so the same
            // tap that ended the run doesn't immediately reshake a
            // die mid-restart.
            if phase.contains(.down) { restartFromGameOver() }
            return .handled
        }
        if winStart != nil {
            if phase.contains(.down) { restartFromWin() }
            return .handled
        }
        // Inventory swallows SPACE so it can't shake a die behind the
        // overlay.
        if inventoryOpen { return .handled }
        let down = phase.contains(.down)
        let up = phase.contains(.up)
        if up { shakingDie = false }
        if inBattle {
            if resolvingRoll { return .handled }
            if awaitingRoll {
                if down { shakingDie = true }
                return .handled
            }
            if down { confirmMenuSelection() }
            return .handled
        }
        if down { return handleInteract() }
        return .ignored
    }

    // MARK: - Battle event

    /// Phantasy-Star-style action menu. Item and Hack are still
    /// placeholders; Fight and Flee both kick off die rolls and
    /// resolve via `handleRollResult`.
    /// Prompt shown in the bottom-right of the battle HUD when a die
    /// roll is pending. Distinguishes Fight from Flee so the player
    /// knows what they're about to roll for.
    private var rollPromptText: String {
        switch pendingRoll {
        case .attack: return Lexicon.rollPrompt(strike: true)
        case .flee:   return Lexicon.rollPrompt(strike: false)
        case .none:   return ""
        }
    }

    private var battleMenuOptions: [BattleMenuOption] {
        [
            BattleMenuOption(name: Lexicon.menuFight, enabled: true),
            BattleMenuOption(name: Lexicon.menuItem,  enabled: false),
            BattleMenuOption(name: Lexicon.menuHack,  enabled: hackChargesRemaining > 0),
            BattleMenuOption(name: Lexicon.menuFlee,  enabled: true),
        ]
    }

    private func startBattle() {
        inBattle = true
        battleMenuIndex = 0
        pendingRoll = nil
        keyboardFocused = true
        // Roll fresh enemy stats per encounter, scaled to the current
        // floor. Same enemy type for now (only Shade exists); add the
        // type-selection roll when there are more enemies to draw from.
        enemyStats = currentEnemyType.baselineStats(floor: dungeonMap.floor)
        // New battle: clear the previous defeat marker and bump the
        // epoch so FightView3D resets any exploded enemy state.
        defeatedEnemyAt = nil
        hitImpactStart = nil
        enemyHitImpactStart = nil
        enemyActedThisRound = false
        // Hack budget for this fight: 1 base + 1 per equipped item with
        // the .extraHack special. Spent on both success and failure.
        hackChargesRemaining = 1 + equipped.values.filter { $0.special == .extraHack }.count
        battleEpoch += 1
        camera.appendGameMessage(Lexicon.battleStart(enemyName))
        // Kick off the pixel-shatter + ENGAGE intro and clear the
        // flag when it finishes. Battle inputs gate on this so the
        // player can't shake the die before the overlay clears.
        let start = Date()
        fightTransitionStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + BattleTransitionView.totalDuration) {
            // Only clear if a fresh transition hasn't started in the
            // meantime (defensive — shouldn't happen mid-battle).
            if fightTransitionStart == start { fightTransitionStart = nil }
        }
    }

    private func endBattle() {
        inBattle = false
        pendingRoll = nil
        shakingDie = false
    }

    private func confirmMenuSelection() {
        let opt = battleMenuOptions[battleMenuIndex]
        guard opt.enabled else {
            if opt.name == Lexicon.menuHack {
                camera.appendGameMessage(Lexicon.hackSpent())
            } else {
                camera.appendGameMessage(Lexicon.notAvailable(opt.name))
            }
            return
        }
        // Hack opens the terminal window — no die roll. The outcome
        // is posted on `camera.hackOutcome` and handled by the watcher
        // below. Bail before the Fight/Flee roll setup.
        if opt.name == Lexicon.menuHack {
            beginHack()
            return
        }
        let kind: PendingRoll
        let prompt: String
        if opt.name == Lexicon.menuFight {
            kind = .attack
            prompt = Lexicon.readyStrike()
        } else if opt.name == Lexicon.menuFlee {
            kind = .flee
            prompt = Lexicon.readyFlee()
        } else {
            return
        }
        // Reset the round budget before deciding initiative. Tie goes
        // to the player so a 1-SPD vs 1-SPD shade doesn't always
        // preempt — defender's advantage.
        enemyActedThisRound = false
        let eff = effectivePlayerStats
        if enemyStats.spd > eff.spd {
            camera.appendGameMessage(
                Lexicon.foeFaster(enemyName, foeSpd: enemyStats.spd, playerSpd: eff.spd)
            )
            // Gate input during the enemy preempt. Open the player's
            // die window only after the laser resolves and the player
            // is still standing.
            resolvingRoll = true
            runEnemyTurn {
                pendingRoll = kind
                camera.appendGameMessage(prompt)
            }
        } else {
            pendingRoll = kind
            camera.appendGameMessage(prompt)
        }
    }

    /// Hack flow entry. Mirrors the initiative check from Fight/Flee —
    /// a faster foe preempts before the terminal opens. After the
    /// preempt (or immediately, if the player is at least as fast),
    /// opens the hack window. `resolvingRoll` stays true the whole
    /// time so battle-menu input is gated until the outcome posts.
    private func beginHack() {
        enemyActedThisRound = false
        camera.hackOutcome = nil
        let eff = effectivePlayerStats
        if enemyStats.spd > eff.spd {
            camera.appendGameMessage(
                Lexicon.foeFaster(enemyName, foeSpd: enemyStats.spd, playerSpd: eff.spd)
            )
            resolvingRoll = true
            runEnemyTurn {
                // runEnemyTurn flips resolvingRoll off before this
                // chain fires. Re-gate and open the terminal.
                resolvingRoll = true
                camera.appendGameMessage(Lexicon.hackReady())
                openWindow(id: "hack")
            }
        } else {
            resolvingRoll = true
            camera.appendGameMessage(Lexicon.hackReady())
            openWindow(id: "hack")
        }
    }

    /// Resolves the outcome posted by HackView. Success applies a
    /// MAG-vs-MDF damage hit, scaled by the score the player earned
    /// (currently from leftover meter time). Failure costs the
    /// player's turn and hands the enemy a free swing — same penalty
    /// shape as a botched Flee, but unconditional.
    private func handleHackOutcome(_ outcome: HackOutcome) {
        dismissWindow(id: "hack")
        // Both success and failure spend a charge — the attempt itself
        // is what's gated, not its result.
        hackChargesRemaining = max(0, hackChargesRemaining - 1)
        var endsBattle = false
        switch outcome {
        case .success(let score):
            let eff = effectivePlayerStats
            let damage = max(1, eff.mag + score - enemyStats.magDef)
            enemyStats.hp = max(0, enemyStats.hp - damage)
            camera.appendGameMessage(
                Lexicon.hackSuccess(foe: enemyName, damage: damage,
                                    mag: eff.mag, score: score,
                                    mdf: enemyStats.magDef)
            )
            triggerHitImpact()
            if enemyStats.hp == 0 {
                camera.appendGameMessage(Lexicon.foeCollapses(enemyName))
                clearDefeatedEnemyTile()
                defeatedEnemyAt = Date()
                endsBattle = true
            }
        case .failure:
            camera.appendGameMessage(Lexicon.hackFailure(enemyName))
        }
        // Same post-action cadence as handleRollResult: brief beat,
        // then either close the battle or yield to the enemy turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postRollHoldSeconds) {
            if endsBattle {
                resolvingRoll = false
                endBattle()
            } else if enemyActedThisRound {
                // Enemy already swung this round (preempt). Don't
                // give them a second turn.
                resolvingRoll = false
            } else {
                runEnemyTurn()
            }
        }
    }

    /// Single dispatch point for every die roll resolved inside a
    /// battle. `pendingRoll` decided what was being attempted; this
    /// applies the outcome and decides whether the battle ends.
    private func handleRollResult(_ roll: Int) {
        guard let kind = pendingRoll, !resolvingRoll else { return }
        resolvingRoll = true
        var endsBattle = false
        switch kind {
        case .attack:
            // Locked damage formula (d6 base):
            //   damage = max(1, str + roll - physDef) + crit-bonus
            // Roll 1 = critical miss (skips clamp, zero damage).
            // Roll 6 = critical hit (adds flat +2 on top of the
            // normal calc). Both produce extra log flavor.
            if roll == 1 {
                camera.appendGameMessage(Lexicon.critMissStrike())
            } else {
                let eff = effectivePlayerStats
                // Keen Edge widens the crit window to 5-6.
                let isCrit = roll == 6 || (roll == 5 && hasSpecial(.keenEdge))
                let base = eff.str + roll - enemyStats.physDef
                let damage = max(1, base + (isCrit ? 2 : 0))
                enemyStats.hp = max(0, enemyStats.hp - damage)
                camera.appendGameMessage(
                    Lexicon.strikeHit(roll: roll, foe: enemyName, damage: damage,
                                      str: eff.str, pdf: enemyStats.physDef,
                                      crit: isCrit)
                )
                triggerHitImpact()
                // Lifesteal: a connecting strike returns 2 HP, capped
                // at the gear-adjusted max.
                if hasSpecial(.lifesteal) && enemyStats.hp >= 0 {
                    let healed = min(2, eff.maxHP - playerStats.hp)
                    if healed > 0 {
                        playerStats.hp += healed
                        camera.appendGameMessage(Lexicon.lifestealTick(healed))
                    }
                }
                if enemyStats.hp == 0 {
                    camera.appendGameMessage(Lexicon.foeCollapses(enemyName))
                    clearDefeatedEnemyTile()
                    defeatedEnemyAt = Date()
                    endsBattle = true
                }
            }
        case .flee:
            if hasSpecial(.guaranteedFlee) {
                camera.appendGameMessage(Lexicon.fleeGuaranteed(enemyName))
                endsBattle = true
                break
            }
            switch roll {
            case 1:
                playerStats.hp = max(0, playerStats.hp - 3)
                camera.appendGameMessage(Lexicon.fleeCritFail(enemyName))
            case 2...10:
                playerStats.hp = max(0, playerStats.hp - 1)
                camera.appendGameMessage(Lexicon.fleeFail(roll: roll))
            case 11...19:
                camera.appendGameMessage(Lexicon.fleeEscape(roll: roll))
                endsBattle = true
            case 20:
                enemyStats.hp = max(0, enemyStats.hp - 1)
                camera.appendGameMessage(Lexicon.fleeCritSuccess(enemyName))
                endsBattle = true
            default:
                camera.appendGameMessage(Lexicon.fleeUnclear(roll: roll))
            }
        }
        // Hold the settled die so the player can read the face; on
        // battle-ending rolls this also gates the fade-out. Keep
        // `pendingRoll` set during the hold so the orb's die-kind
        // override doesn't flip back mid-display.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postRollHoldSeconds) {
            pendingRoll = nil
            if endsBattle {
                resolvingRoll = false
                endBattle()
            } else if enemyActedThisRound {
                // The shade already preempted this round on initiative.
                // Skip its second turn so speed shifts order, not count.
                resolvingRoll = false
            } else {
                // Player's beat is over — shade gets its turn next.
                // `resolvingRoll` stays true through the enemy turn so
                // a stray key can't kick off a second shake mid-laser.
                runEnemyTurn()
            }
        }
    }

    /// Length of the eye-glow telegraph before the laser snaps on.
    /// Tuned with `Self.enemyBeamFade` so the full enemy turn is just
    /// under a second.
    private static let enemyWindupSeconds: Double = 0.55
    /// Tail time after the beam fires — how long it lingers before
    /// fading out and we hand control back to the player.
    private static let enemyBeamFade: Double = 0.4

    /// Shade's turn. Hidden d6 roll mirroring the player's crit table
    /// so the rule reads symmetric even though the enemy's die isn't
    /// tactile. The eye-laser visual is decorative — damage and the
    /// red screen-flash both fire on the beam-land moment so they
    /// sync to the cinematic. Pass `then` to chain a follow-up
    /// (e.g. open the player's die window after a preempt strike).
    private func runEnemyTurn(then: (() -> Void)? = nil) {
        enemyActedThisRound = true
        let roll = Int.random(in: 1...6)
        let isCritMiss = (roll == 1)
        let isCritHit = (roll == 6)
        let effPdf = effectivePlayerStats.physDef
        let base = enemyStats.str + roll - effPdf
        let damage = isCritMiss ? 0 : max(1, base + (isCritHit ? 2 : 0))

        // Kick the visual immediately. FightView3D drives windup +
        // beam timing; the numbers below stay in sync with it.
        enemyAttackAt = Date()

        let windup = Self.enemyWindupSeconds
        let beamFade = Self.enemyBeamFade

        // Beam-impact moment: apply damage, red flash + shake, log.
        DispatchQueue.main.asyncAfter(deadline: .now() + windup) {
            if isCritMiss {
                camera.appendGameMessage(Lexicon.foeMisses(enemyName))
            } else {
                playerStats.hp = max(0, playerStats.hp - damage)
                camera.appendGameMessage(
                    Lexicon.foeHit(enemyName, damage: damage, str: enemyStats.str,
                                   roll: roll, pdf: effPdf,
                                   crit: isCritHit)
                )
                triggerEnemyHitImpact()
            }
        }

        // Hand control back after the beam fades. KO triggers the
        // Game Over outro (shatter + prompt); otherwise run the
        // optional chain (used by the preempt path to open the
        // player's die window).
        DispatchQueue.main.asyncAfter(deadline: .now() + windup + beamFade) {
            resolvingRoll = false
            if playerStats.hp == 0 {
                camera.appendGameMessage(Lexicon.defeated(enemyName))
                triggerGameOver()
            } else {
                then?()
            }
        }
    }

    /// Kick off the shatter outro. Leaves `inBattle` true so the
    /// FightView3D backdrop stays visible behind the cells while they
    /// pop in, but clears every other transient battle flag so a
    /// half-finished animation can't tick over the top of the
    /// outro.
    private func triggerGameOver() {
        gameOverStart = Date()
        pendingRoll = nil
        resolvingRoll = false
        shakingDie = false
        enemyActedThisRound = false
    }

    /// SPACE handler when the Game Over screen is up. Resets player
    /// stats, jumps to floor 1 (restoring the cached version if the
    /// player had explored it earlier so reveal state is preserved),
    /// and clears the outro. The death-floor map is *not* saved into
    /// the cache — the player's position there would be on the enemy
    /// tile they died on, which would re-trigger the same fight if
    /// they revisited.
    private func restartFromGameOver() {
        playerStats = Stats(
            hp: 20, maxHP: 20, mp: 10, maxMP: 10,
            str: 1, spd: 1, physDef: 1, mag: 1, magDef: 1
        )
        enemyStats = currentEnemyType.baselineStats(floor: 1)
        inBattle = false
        pendingRoll = nil
        resolvingRoll = false
        enemyActedThisRound = false
        fightTransitionStart = nil
        hitImpactStart = nil
        enemyHitImpactStart = nil
        defeatedEnemyAt = nil
        enemyAttackAt = nil
        shakingDie = false
        if let saved = floorsByNumber[1] {
            dungeonMap = saved
        } else {
            dungeonMap = DungeonMap.make(floor: 1)
        }
        gameOverStart = nil
        backpack = []
        equipped = [:]
        camera.appendGameMessage(Lexicon.wake())
    }

    /// DEMO: kick off the win-screen outro when floor 5's door is
    /// cleared. Mirrors `triggerGameOver` — clears transient flags so
    /// nothing animates over the outro — but is reached from dungeon
    /// navigation, not combat, so there's no battle state to unwind.
    private func triggerWin() {
        winStart = Date()
        pendingRoll = nil
        resolvingRoll = false
        shakingDie = false
        inBattle = false
    }

    /// SPACE handler when the win screen is up. Same fresh-run reset
    /// as `restartFromGameOver` (floor 1, base stats, loot wiped),
    /// just clearing `winStart` instead of `gameOverStart`.
    private func restartFromWin() {
        playerStats = Stats(
            hp: 20, maxHP: 20, mp: 10, maxMP: 10,
            str: 1, spd: 1, physDef: 1, mag: 1, magDef: 1
        )
        enemyStats = currentEnemyType.baselineStats(floor: 1)
        inBattle = false
        pendingRoll = nil
        resolvingRoll = false
        enemyActedThisRound = false
        fightTransitionStart = nil
        hitImpactStart = nil
        enemyHitImpactStart = nil
        defeatedEnemyAt = nil
        enemyAttackAt = nil
        shakingDie = false
        floorsByNumber.removeAll()
        dungeonMap = DungeonMap.make(floor: 1)
        winStart = nil
        backpack = []
        equipped = [:]
        camera.appendGameMessage(Lexicon.wake())
    }

    // MARK: Gear acquisition / management

    /// Opt-in: open the chest the player is standing on. Never auto-
    /// fires — a player who wants the bodysuit-only run just never
    /// presses interact on chests. Rolls a depth-scaled item into the
    /// backpack and spends the chest tile so it can't be re-opened. A
    /// full backpack refuses (forcing a manage-gear decision first),
    /// and the chest stays openable for when space is freed.
    private func openChestHere() {
        let r = dungeonMap.playerRow, c = dungeonMap.playerCol
        guard dungeonMap.tiles[r][c].kind == .chest else { return }
        guard backpack.count < Self.backpackCap else {
            camera.appendGameMessage(Lexicon.backpackFull(Self.backpackCap))
            return
        }
        let item = GearItem.roll(floor: dungeonMap.floor)
        backpack.append(item)
        dungeonMap.tiles[r][c].kind = .openedChest
        camera.appendGameMessage(Lexicon.chestOpened(item.name, summary: item.summary))
    }

    /// Equip a backpack item into its slot. Whatever was in that slot
    /// returns to the backpack. Pools reconcile via the before/after
    /// effective-max diff so a slot swap can't double-count.
    private func equip(_ item: GearItem) {
        guard let idx = backpack.firstIndex(where: { $0.id == item.id }) else { return }
        reconcilePools {
            backpack.remove(at: idx)
            if let prev = equipped[item.slot] { backpack.append(prev) }
            equipped[item.slot] = item
        }
        camera.appendGameMessage(Lexicon.equipped(item.name, slot: item.slot.label))
    }

    /// Move an equipped item back to the backpack (if there's room).
    private func unequip(_ slot: GearSlot) {
        guard let item = equipped[slot] else { return }
        guard backpack.count < Self.backpackCap else {
            camera.appendGameMessage(Lexicon.backpackFull(Self.backpackCap))
            return
        }
        reconcilePools {
            equipped[slot] = nil
            backpack.append(item)
        }
        camera.appendGameMessage(Lexicon.unequipped(item.name))
    }

    private func discard(_ item: GearItem) {
        guard let idx = backpack.firstIndex(where: { $0.id == item.id }) else { return }
        backpack.remove(at: idx)
        camera.appendGameMessage(Lexicon.discarded(item.name))
    }

    /// Run an equip mutation, then keep current HP/MP coherent with
    /// the new effective maxima: a net gain is granted live (the
    /// buffer is felt immediately); a net loss clamps current down,
    /// never below 1 HP so removing armor can't be lethal.
    private func reconcilePools(_ mutate: () -> Void) {
        let before = effectivePlayerStats
        mutate()
        let after = effectivePlayerStats
        if after.maxHP > before.maxHP { playerStats.hp += after.maxHP - before.maxHP }
        if after.maxMP > before.maxMP { playerStats.mp += after.maxMP - before.maxMP }
        playerStats.hp = max(1, min(playerStats.hp, after.maxHP))
        playerStats.mp = max(0, min(playerStats.mp, after.maxMP))
    }

    /// Kick off the white-flash + screen-shake feedback that plays
    /// whenever the *player's* hit lands on the enemy. Auto-clears
    /// after 0.3s so the driving TimelineView pauses again.
    private func triggerHitImpact() {
        let start = Date()
        hitImpactStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            if hitImpactStart == start { hitImpactStart = nil }
        }
    }

    /// Kick off the red full-screen wash + heavier shake the moment
    /// the shade's laser visually lands on the camera. Distinct from
    /// `triggerHitImpact` so the player→enemy and enemy→player
    /// directions read at a glance.
    private func triggerEnemyHitImpact() {
        let start = Date()
        enemyHitImpactStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.enemyImpactDuration + 0.05) {
            if enemyHitImpactStart == start { enemyHitImpactStart = nil }
        }
    }

    /// How long the red overlay lingers after the beam lands. Longer
    /// than the player's white pop so it reads as taking a serious
    /// hit, but short enough not to bleed into the next menu open.
    private static let enemyImpactDuration: Double = 0.55

    /// Computes the current flash opacities and shake offset for the
    /// fight ZStack. The TimelineView wrapping the ZStack feeds in
    /// the current frame's `Date` and pauses when no impact is
    /// pending so this isn't hot in the steady state.
    private func impactValues(now: Date) -> (whiteFlash: Double, redFlash: Double, shake: CGSize) {
        var whiteFlash: Double = 0
        var shake = CGSize.zero
        if let start = hitImpactStart {
            let elapsed = now.timeIntervalSince(start)
            let flashDur: Double = 0.15
            let shakeDur: Double = 0.22
            whiteFlash = elapsed < flashDur
                ? max(0, 1 - elapsed / flashDur) * 0.55
                : 0
            if elapsed < shakeDur {
                let damping = 1.0 - (elapsed / shakeDur)
                let intensity = 7.0 * damping
                let angle = elapsed * 80
                shake = CGSize(width: cos(angle) * intensity,
                               height: sin(angle * 1.4) * intensity * 0.6)
            }
        }
        // Enemy laser impact stacks its own (red) flash + heavier shake.
        // Two impacts overlapping is unlikely in practice but the math
        // adds them so a stray collision doesn't blank one out.
        var redFlash: Double = 0
        if let start = enemyHitImpactStart {
            let elapsed = now.timeIntervalSince(start)
            let dur = Self.enemyImpactDuration
            let rampIn: Double = 0.05
            // Quick ramp up, then linear fade out — feels like the
            // beam slammed the camera then the world recovers.
            let curve: Double = elapsed < rampIn
                ? (elapsed / rampIn)
                : max(0, 1 - (elapsed - rampIn) / (dur - rampIn))
            redFlash = curve * 0.78
            let shakeDur: Double = 0.42
            if elapsed < shakeDur {
                let damping = 1.0 - (elapsed / shakeDur)
                let intensity = 14.0 * damping
                let angle = elapsed * 90
                shake.width  += cos(angle) * intensity
                shake.height += sin(angle * 1.4) * intensity * 0.6
            }
        }
        return (whiteFlash, redFlash, shake)
    }

    /// Convert the tile the player is standing on from `.enemy` to
    /// `.empty` after a Fight victory. Used so a dead enemy doesn't
    /// keep re-triggering battles when the player walks away and
    /// back. Flee victories don't call this — the enemy is still
    /// alive on its tile.
    private func clearDefeatedEnemyTile() {
        let r = dungeonMap.playerRow, c = dungeonMap.playerCol
        guard dungeonMap.tiles[r][c].kind == .enemy else { return }
        dungeonMap.tiles[r][c].kind = .empty
    }

    private func logStep(_ kind: DungeonTileKind?) {
        guard let kind else { return }
        switch kind {
        case .empty:    camera.appendGameMessage(Lexicon.stepEmpty())
        case .wall:     break  // unreachable — step() rejects wall tiles
        case .chest:    camera.appendGameMessage(Lexicon.chestHere("Press space"))
        case .openedChest: camera.appendGameMessage(Lexicon.chestSpent())
        case .enemy:    camera.appendGameMessage(Lexicon.stepFoe())
        case .door:     camera.appendGameMessage(Lexicon.stepDoorDown("Press space"))
        case .stairsUp: camera.appendGameMessage(Lexicon.stepStairsUp("Press space"))
        case .keyChest:
            camera.appendGameMessage(Lexicon.keyFound())
        case .lockedDoor:
            camera.appendGameMessage(Lexicon.lockedGate(hasKey: dungeonMap.hasKey,
                                                        advance: "Press space"))
        }
    }

    private func cameraPreview() -> some View {
        standardOverlays(
            CameraPreview(session: camera.session, hands: camera.hands),
            embedOrb: false
        )
        .onAppear { camera.acquire() }
        .onDisappear { camera.release() }
    }

    /// Inner ZStack for the dungeon/fight scene, including the
    /// hit-flash and screen-shake driven by `now`. Extracted from
    /// `dungeonView3D` because the combined expression confused
    /// SwiftUI's generic inference when wrapped in TimelineView.
    @ViewBuilder
    private func fightLayerStack(at now: Date) -> some View {
        let (flashAlpha, redAlpha, shake) = impactValues(now: now)
        ZStack {
            DungeonView3D(map: dungeonMap)
                .opacity(inBattle ? 0 : 1)
                .allowsHitTesting(!inBattle)
            FightView3D(battleEpoch: battleEpoch,
                         defeatedAt: defeatedEnemyAt,
                         attackAt: enemyAttackAt)
                .opacity(inBattle ? 1 : 0)
                .allowsHitTesting(inBattle)
            BattleHUD(enemyName: enemyName,
                      enemyHP: enemyStats.hp, enemyMaxHP: enemyStats.maxHP,
                      playerHP: playerStats.hp, playerMaxHP: effectivePlayerStats.maxHP,
                      menu: battleMenuOptions,
                      menuIndex: battleMenuIndex,
                      awaitingRoll: awaitingRoll,
                      rollPrompt: rollPromptText,
                      resolvingRoll: resolvingRoll,
                      rollValue: camera.dieResult)
                .opacity(inBattle ? 1 : 0)
                .allowsHitTesting(false)
            if let started = fightTransitionStart {
                BattleTransitionView(startedAt: started)
                    .allowsHitTesting(false)
            }
            // Red wash — enemy laser landing on the camera. Drawn
            // first so the white player-hit pop sits on top of it
            // (the two rarely overlap, but if they do the white spike
            // remains legible).
            Rectangle()
                .fill(Color(red: 1.0, green: 0.08, blue: 0.12))
                .opacity(redAlpha)
                .allowsHitTesting(false)
            // White hit flash — drawn last so it sits over HUD too.
            Rectangle()
                .fill(Color.white)
                .opacity(flashAlpha)
                .allowsHitTesting(false)
            // Game Over outro is rendered full-window by the body-
            // level overlay (paired with the win screen) so it covers
            // the 2D map + text log too, not just this pane.
        }
        .offset(shake)
    }

    private func dungeonView3D() -> some View {
        // Keep both 3D scenes in the view hierarchy at all times and
        // swap via opacity instead of an if/else conditional. SceneKit
        // JIT-compiles Metal pipeline state on a scene's first draw,
        // which stalls the main thread for ~1s the first time you
        // step on an enemy tile if FightView3D is created on demand.
        // Building it at launch warms the shader cache so the swap
        // is instant.
        standardOverlays(
            TimelineView(.animation(minimumInterval: 1.0/60.0,
                                     paused: hitImpactStart == nil
                                          && enemyHitImpactStart == nil)) { ctx in
                fightLayerStack(at: ctx.date)
            },
            // Only show the die window when a roll is actually
            // pending or resolving — otherwise the d20 sits there
            // during menu nav and visibly swaps to a d6 the moment
            // FIGHT is chosen, which reads as a glitch.
            embedOrb: awaitingRoll || resolvingRoll
        )
        .overlay(alignment: .bottomLeading) {
            // Hide the on-screen turn buttons in arrow-keys mode (←/→
            // do the same thing) and during combat (you can't turn
            // mid-fight). Turn buttons stay otherwise.
            if !arrowMode && !inBattle {
                HStack(spacing: 12) {
                    turnButton("◀") { dungeonMap.turn(by: -1) }
                    turnButton("▶") { dungeonMap.turn(by: 1) }
                }
                .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Debug-only: inspect both combatants' stat blocks during
            // a battle. Not part of the shipping UI — strip when
            // combat balance settles.
            if inBattle {
                HStack(alignment: .top, spacing: 10) {
                    DebugPlayerStatsView(stats: effectivePlayerStats)
                        .frame(width: 120)
                    DebugEnemyStatsView(name: enemyName,
                                         stats: enemyStats,
                                         floor: dungeonMap.floor)
                        .frame(width: 120)
                }
                .padding(.top, 20)
                .padding(.trailing, 20)
            }
        }
    }

    private func turnButton(_ glyph: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// What die the embedded orb should display. nil means "user's
    /// preference" (Adventure mode → d20). During Fight rolls we
    /// override to d6 so the dice progression can grow via pool size
    /// rather than die size.
    private var embeddedOrbDieKindOverride: String? {
        pendingRoll == .attack ? DieKind.d6.rawValue : nil
    }

    @ViewBuilder
    private func standardOverlays<Base: View>(_ base: Base,
                                              embedOrb: Bool) -> some View {
        base
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
                        EmbeddedOrbView(shaking: shakingDie,
                                        dieKindOverride: embeddedOrbDieKindOverride)
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
    }
}

enum DungeonTileKind {
    case empty, wall, chest, enemy, door, stairsUp
    /// A chest that also holds the floor's key. Visually distinct so a
    /// revealed key chest reads as the objective at a glance.
    case keyChest
    /// A descent door sealed until the player carries this floor's key.
    /// Floors below `DungeonMap.keyFloorStart` never produce these.
    case lockedDoor
    /// A chest the player has already opened. Inert and visually
    /// spent so it won't re-trigger; un-opened chests stay `.chest`.
    case openedChest
}

struct DungeonTile {
    var kind: DungeonTileKind
    var revealed: Bool
}

struct DungeonMap {
    static let columns = 16
    static let rows = 12
    /// First floor where the stairwell is sealed and a key must be
    /// found to descend. Floors below this are the plain ruleset.
    static let keyFloorStart = 6

    var tiles: [[DungeonTile]]
    var floor: Int
    /// True once the player has stepped onto this floor's key chest.
    /// Lives on the map so it persists with the cached floor across
    /// ascend/descend. Floors without a key never set it.
    var hasKey: Bool = false
    /// Current player tile (row, col). Reachability is measured from
    /// here, and the 3D camera is parked over this tile.
    var playerRow: Int
    var playerCol: Int
    /// 0 = north (toward row 0), 1 = east, 2 = south, 3 = west.
    /// Drives the 3D camera yaw and the player marker on the 2D map.
    var playerFacing: Int

    /// `spawn` lets a descending floor land the player at the same
    /// (row, col) as the door they used — so a floor stitches
    /// geographically onto the one above it. Defaults to map center
    /// for floor 1. `spawnIsStairsUp` places a stairs-up tile there so
    /// the player can climb back; floor 1 leaves it empty.
    static func make(floor: Int,
                     spawn: (row: Int, col: Int)? = nil,
                     spawnIsStairsUp: Bool = false) -> DungeonMap {
        var grid: [[DungeonTile]] = (0..<rows).map { _ in
            (0..<columns).map { _ in
                DungeonTile(kind: randomKind(), revealed: false)
            }
        }
        let sr = spawn?.row ?? rows / 2
        let sc = spawn?.col ?? columns / 2
        grid[sr][sc].kind = spawnIsStairsUp ? .stairsUp : .empty
        grid[sr][sc].revealed = true

        // Flood-fill from spawn over non-wall tiles to find the
        // playable region. Anything outside it is unreachable, so the
        // door (the only way down) must live inside it.
        var reachable = Array(repeating: Array(repeating: false, count: columns),
                              count: rows)
        var stack: [(Int, Int)] = [(sr, sc)]
        reachable[sr][sc] = true
        while let (r, c) = stack.popLast() {
            for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nr = r + dr, nc = c + dc
                guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                guard !reachable[nr][nc] else { continue }
                guard grid[nr][nc].kind != .wall else { continue }
                reachable[nr][nc] = true
                stack.append((nr, nc))
            }
        }

        var reachableCoords: [(Int, Int)] = []
        var hasReachableDoor = false
        for r in 0..<rows {
            for c in 0..<columns {
                guard reachable[r][c] else { continue }
                reachableCoords.append((r, c))
                if grid[r][c].kind == .door { hasReachableDoor = true }
            }
        }
        if !hasReachableDoor {
            let candidates = reachableCoords.filter { !($0.0 == sr && $0.1 == sc) }
            if let pick = candidates.randomElement() {
                grid[pick.0][pick.1].kind = .door
            } else {
                // Spawn boxed in by walls on all four sides — knock one
                // out and put the door there.
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = sr + dr, nc = sc + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                    grid[nr][nc].kind = .door
                    break
                }
            }
        }

        // From `keyFloorStart` the stairwell is sealed: every door on
        // the floor becomes a `.lockedDoor`, and one reachable chest
        // (or, failing that, a reachable empty tile) becomes the
        // `.keyChest`. Only commit the lock if a reachable key spot
        // exists — otherwise a degenerate boxed-in floor would be an
        // unescapable softlock, so it stays the plain ruleset.
        if floor >= Self.keyFloorStart {
            let notSpawn: ((Int, Int)) -> Bool = { !($0.0 == sr && $0.1 == sc) }
            let keySpot =
                reachableCoords.filter { notSpawn($0) && grid[$0.0][$0.1].kind == .chest }
                    .randomElement()
                ?? reachableCoords.filter { notSpawn($0) && grid[$0.0][$0.1].kind == .empty }
                    .randomElement()
            if let keySpot {
                for r in 0..<rows {
                    for c in 0..<columns where grid[r][c].kind == .door {
                        grid[r][c].kind = .lockedDoor
                    }
                }
                grid[keySpot.0][keySpot.1].kind = .keyChest
            }
        }

        var map = DungeonMap(tiles: grid, floor: floor,
                             playerRow: sr, playerCol: sc,
                             playerFacing: 0)
        map.revealAdjacentWalls(row: sr, col: sc)
        return map
    }

    private static func randomKind() -> DungeonTileKind {
        switch Double.random(in: 0..<1) {
        case ..<0.62: return .empty
        case ..<0.74: return .wall
        case ..<0.86: return .chest
        case ..<0.96: return .enemy
        default:      return .door
        }
    }

    /// True if (row, col) is one orthogonal step from the player and
    /// in bounds. Defines both "tiles the player can step into" and
    /// "tiles to highlight on the 3D floor."
    func canMoveTo(row: Int, col: Int) -> Bool {
        guard row >= 0, row < Self.rows, col >= 0, col < Self.columns else { return false }
        guard tiles[row][col].kind != .wall else { return false }
        let dr = abs(row - playerRow)
        let dc = abs(col - playerCol)
        return (dr + dc) == 1
    }

    /// Mark wall tiles 4-adjacent to (row, col) as revealed so the
    /// player can see the walls of the area they're standing in. Open
    /// tiles get revealed by stepping onto them — walls never can,
    /// so we surface them indirectly.
    mutating func revealAdjacentWalls(row: Int, col: Int) {
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nr = row + dr, nc = col + dc
            guard nr >= 0, nr < Self.rows, nc >= 0, nc < Self.columns else { continue }
            if tiles[nr][nc].kind == .wall { tiles[nr][nc].revealed = true }
        }
    }

    /// Move the player onto (row, col), auto-turning to face the
    /// direction of travel. Returns the tile kind iff the destination
    /// was newly revealed by the move (so callers can log the
    /// discovery). Returns nil for no-op moves and for moves onto
    /// already-revealed tiles.
    mutating func step(toRow row: Int, col: Int) -> DungeonTileKind? {
        guard canMoveTo(row: row, col: col) else { return nil }
        if row < playerRow      { playerFacing = 0 }   // north
        else if row > playerRow { playerFacing = 2 }   // south
        else if col > playerCol { playerFacing = 1 }   // east
        else                    { playerFacing = 3 }   // west
        let wasRevealed = tiles[row][col].revealed
        tiles[row][col].revealed = true
        playerRow = row
        playerCol = col
        grabKeyIfPresent(row, col)
        revealAdjacentWalls(row: row, col: col)
        return wasRevealed ? nil : tiles[row][col].kind
    }

    /// Picking up the floor's key is just stepping onto its chest. The
    /// chest tile stays a `.keyChest` (its discovery message fires once
    /// via `step`'s revealed-gate); `hasKey` is what gates the door.
    private mutating func grabKeyIfPresent(_ r: Int, _ c: Int) {
        if tiles[r][c].kind == .keyChest { hasKey = true }
    }

    /// Rotate the player in place. `delta = +1` turns right (clockwise
    /// from above), `-1` turns left.
    mutating func turn(by delta: Int) {
        playerFacing = ((playerFacing + delta) % 4 + 4) % 4
    }

    /// (dr, dc) for the tile one square forward of the player. Used by
    /// arrow-key controls.
    private func forwardOffset() -> (dr: Int, dc: Int) {
        switch playerFacing {
        case 0:  return (-1, 0)   // north
        case 1:  return (0, 1)    // east
        case 2:  return (1, 0)    // south
        case 3:  return (0, -1)   // west
        default: return (0, 0)
        }
    }

    /// Step one tile forward or backward along the current facing,
    /// preserving facing. Returns the discovered tile kind iff the
    /// destination was newly revealed.
    mutating func step(forward: Bool) -> DungeonTileKind? {
        let off = forwardOffset()
        let dr = forward ? off.dr : -off.dr
        let dc = forward ? off.dc : -off.dc
        let r = playerRow + dr
        let c = playerCol + dc
        guard r >= 0, r < Self.rows, c >= 0, c < Self.columns else { return nil }
        guard tiles[r][c].kind != .wall else { return nil }
        let wasRevealed = tiles[r][c].revealed
        tiles[r][c].revealed = true
        playerRow = r
        playerCol = c
        grabKeyIfPresent(r, c)
        revealAdjacentWalls(row: r, col: c)
        return wasRevealed ? nil : tiles[r][c].kind
    }
}

struct DungeonMapView: View {
    @Binding var map: DungeonMap
    @AppStorage(AdventureControls.storageKey) private var controls: String = AdventureControls.click.rawValue
    var onStairs: () -> Void
    /// External lockout (e.g., battle in progress). When true, all
    /// taps no-op — movement and stair use must wait until the lock
    /// clears.
    var disabled: Bool = false
    var log: (String) -> Void
    /// Invoked when the player re-activates their own tile while
    /// standing on a chest — opens it parent-side (opt-in).
    var onChest: () -> Void

    private var clickToMove: Bool {
        controls == AdventureControls.click.rawValue && !disabled
    }

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
                visionCone(viewSize: geo.size, side: side)
                    .fill(Color(red: 1.0, green: 0.95, blue: 0.4).opacity(0.18))
                    .allowsHitTesting(false)
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
        let isPlayer = (row == map.playerRow && col == map.playerCol)
        let reachable = map.canMoveTo(row: row, col: col)
        Button {
            handleTap(row: row, col: col)
        } label: {
            ZStack {
                Rectangle().fill(tileFill(tile: tile,
                                          isPlayer: isPlayer,
                                          reachable: reachable))
                if tile.revealed {
                    Text(glyph(for: tile.kind))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(glyphColor(for: tile.kind))
                }
                if isPlayer {
                    Text(playerGlyph(facing: map.playerFacing))
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.95, blue: 0.4))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!clickToMove || (!isPlayer && !reachable))
    }

    private func handleTap(row: Int, col: Int) {
        // In arrow-keys mode the 2D map is display-only — movement
        // and descent happen via the keyboard.
        guard clickToMove else { return }
        let isPlayer = (row == map.playerRow && col == map.playerCol)
        // Re-clicking your own tile: take stairs if there are any
        // (down on a door, up on a stairs-up tile). The parent owns
        // the floor-history stack so we route through `onStairs`
        // rather than mutating the map locally.
        if isPlayer {
            let kind = map.tiles[row][col].kind
            if kind == .door || kind == .lockedDoor || kind == .stairsUp { onStairs() }
            else if kind == .chest { onChest() }
            return
        }
        guard map.canMoveTo(row: row, col: col) else { return }
        let discovered = map.step(toRow: row, col: col)
        // Already-revealed steps are silent — the visible movement is
        // its own feedback. Only newly-revealed tiles log discovery.
        guard let kind = discovered else { return }
        switch kind {
        case .empty:    log(Lexicon.stepEmpty())
        case .wall:     break  // unreachable — step() rejects wall tiles
        case .chest:    log(Lexicon.chestHere("Click again"))
        case .openedChest: log(Lexicon.chestSpent())
        case .enemy:    log(Lexicon.stepFoe())
        case .door:     log(Lexicon.stepDoorDown("Click again"))
        case .stairsUp: log(Lexicon.stepStairsUp("Click again"))
        case .keyChest:
            log(Lexicon.keyFound())
        case .lockedDoor:
            log(Lexicon.lockedGate(hasKey: map.hasKey, advance: "Click again"))
        }
    }

    private func tileFill(tile: DungeonTile,
                          isPlayer: Bool,
                          reachable: Bool) -> Color {
        if isPlayer { return Color(red: 0.0, green: 0.45, blue: 0.55) }
        if tile.kind == .wall && tile.revealed {
            return Color(red: 0.18, green: 0.14, blue: 0.10)
        }
        if tile.revealed { return Color(white: 0.28) }
        return reachable ? Color(white: 0.22) : Color(white: 0.10)
    }

    /// Wedge in the player's facing direction — a low-opacity yellow
    /// "vision cone" that makes facing unambiguous at a glance. Apex
    /// sits at the front edge of the player tile (not the center) so
    /// the cone clearly emanates forward instead of swallowing the
    /// player marker.
    private func visionCone(viewSize: CGSize, side: Double) -> Path {
        let cols = DungeonMap.columns
        let rows = DungeonMap.rows
        let gridW = side * Double(cols)
        let gridH = side * Double(rows)
        let originX = (viewSize.width - gridW) / 2
        let originY = (viewSize.height - gridH) / 2
        let cx = originX + (Double(map.playerCol) + 0.5) * side
        let cy = originY + (Double(map.playerRow) + 0.5) * side

        let (fx, fy): (Double, Double)
        switch map.playerFacing {
        case 0:  (fx, fy) = (0, -1)   // north
        case 1:  (fx, fy) = (1, 0)    // east
        case 2:  (fx, fy) = (0, 1)    // south
        case 3:  (fx, fy) = (-1, 0)   // west
        default: (fx, fy) = (0, -1)
        }
        // Perpendicular to facing (90° clockwise in screen coords).
        let px = -fy, py = fx

        let apexX = cx + fx * (side * 0.5)
        let apexY = cy + fy * (side * 0.5)
        let length = side * 2.6
        let halfWidth = length * tan(35 * .pi / 180)
        let tipX = apexX + fx * length
        let tipY = apexY + fy * length

        var path = Path()
        path.move(to: CGPoint(x: apexX, y: apexY))
        path.addLine(to: CGPoint(x: tipX - px * halfWidth,
                                 y: tipY - py * halfWidth))
        path.addLine(to: CGPoint(x: tipX + px * halfWidth,
                                 y: tipY + py * halfWidth))
        path.closeSubpath()
        return path
    }

    private func playerGlyph(facing: Int) -> String {
        switch facing {
        case 0:  return "▲"
        case 1:  return "▶"
        case 2:  return "▼"
        case 3:  return "◀"
        default: return "●"
        }
    }

    private func glyph(for kind: DungeonTileKind) -> String {
        switch kind {
        case .empty:    return "·"
        case .wall:     return "#"
        case .chest:    return "$"
        case .enemy:    return "E"
        case .door:     return "⌂"
        case .stairsUp: return "↑"
        case .keyChest: return "⚷"
        case .lockedDoor: return "⌂"
        case .openedChest: return "▫"
        }
    }

    private func glyphColor(for kind: DungeonTileKind) -> Color {
        switch kind {
        case .empty:    return Color(white: 0.55)
        case .wall:     return Color(red: 0.95, green: 0.65, blue: 0.35)
        case .chest:    return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .enemy:    return Color(red: 0.92, green: 0.32, blue: 0.32)
        case .door:     return Color(red: 0.40, green: 0.78, blue: 0.95)
        case .stairsUp: return Color(red: 1.00, green: 0.55, blue: 0.75)
        case .keyChest: return Color(red: 1.00, green: 0.84, blue: 0.30)
        case .lockedDoor: return Color(red: 0.95, green: 0.45, blue: 0.45)
        case .openedChest: return Color(white: 0.42)
        }
    }
}

/// First-person Tron-style wireframe view of the dungeon. The character
/// stands on the spawn tile (center of the map) facing toward row 0;
/// revealed tiles render as a neon-green wireframe floor, unknown tiles
/// rise up as neon-blue fog pillars, and revealed contents (chests,
/// enemies, doors) get stylized wireframe markers. The view rebuilds
/// whenever the dungeon map changes.
struct DungeonView3D: NSViewRepresentable {
    let map: DungeonMap

    /// Tracks the camera's unwrapped yaw and last-known map state so
    /// rotations always take the shortest signed path (and so floor
    /// changes can snap rather than animate across the whole map).
    final class Coordinator {
        var cameraYaw: Float = 0
        var lastFacing: Int = 0
        var lastFloor: Int = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor.black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = false

        let scene = SCNScene()
        scene.background.contents = NSColor.black

        // First-person camera. Position and yaw are set in
        // updateCamera so they can track the player tile-by-tile; here
        // we just install the node with a fixed pitch and FOV.
        let camNode = SCNNode()
        camNode.name = Self.cameraTag
        let cam = SCNCamera()
        cam.fieldOfView = 68
        cam.zNear = 0.05
        cam.zFar = 60
        camNode.camera = cam
        // Pitch ~9° downward so the floor in front is visible without
        // hiding the horizon.
        camNode.eulerAngles = SCNVector3(-0.16, 0, 0)
        scene.rootNode.addChildNode(camNode)

        view.scene = scene
        Self.updateCamera(in: scene, map: map, coord: context.coordinator,
                           animated: false)
        Self.rebuildContent(in: scene, map: map)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        guard let scene = nsView.scene else { return }
        Self.updateCamera(in: scene, map: map, coord: context.coordinator,
                           animated: true)
        Self.rebuildContent(in: scene, map: map)
    }

    private static let contentTag = "dungeon-content"
    private static let cameraTag = "dungeon-camera"

    /// Snap or animate the camera to (playerCol, playerRow) with a yaw
    /// matching playerFacing. Uses an *unwrapped* yaw so successive
    /// turns rotate the short way each time instead of unwinding
    /// through 0.
    private static func updateCamera(in scene: SCNScene,
                                     map: DungeonMap,
                                     coord: Coordinator,
                                     animated: Bool) {
        guard let camNode = scene.rootNode.childNode(withName: cameraTag,
                                                      recursively: false) else { return }
        let cols = DungeonMap.columns
        let rows = DungeonMap.rows
        let cx = Float(cols) / 2
        let cz = Float(rows) / 2
        let px = Float(map.playerCol) - cx
        let pz = Float(map.playerRow) - cz

        let floorChanged = map.floor != coord.lastFloor
        if floorChanged {
            // New floor: snap everything (camera teleports across the
            // map and resets facing). Animating that looks wrong.
            coord.cameraYaw = Float(map.playerFacing) * (-.pi / 2)
            coord.lastFacing = map.playerFacing
            coord.lastFloor = map.floor
        } else {
            // Choose the signed delta that takes the short path
            // through the facing wheel (3 → 0 should be +1, not -3).
            var delta = map.playerFacing - coord.lastFacing
            if delta == 3 { delta = -1 }
            else if delta == -3 { delta = 1 }
            coord.cameraYaw += Float(delta) * (-.pi / 2)
            coord.lastFacing = map.playerFacing
        }

        let shouldAnimate = animated && !floorChanged
        if shouldAnimate {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.22
        }
        camNode.position = SCNVector3(px, 0.55, pz)
        camNode.eulerAngles = SCNVector3(-0.16, coord.cameraYaw, 0)
        if shouldAnimate {
            SCNTransaction.commit()
        }
    }

    private static func rebuildContent(in scene: SCNScene, map: DungeonMap) {
        // Clear previous wireframe pass.
        scene.rootNode.childNodes
            .filter { $0.name == contentTag }
            .forEach { $0.removeFromParentNode() }

        let cols = DungeonMap.columns
        let rows = DungeonMap.rows
        let cx = Float(cols) / 2
        let cz = Float(rows) / 2

        func tileCenter(row: Int, col: Int) -> SIMD3<Float> {
            // Row 0 maps to -cz (far ahead of player when facing
            // north). World origin (0,0,0) is the geometric center of
            // the map; the camera moves to track the player tile.
            SIMD3<Float>(Float(col) - cx, 0, Float(row) - cz)
        }

        var floorSegs:    [(SIMD3<Float>, SIMD3<Float>)] = []
        var fogSegs:      [(SIMD3<Float>, SIMD3<Float>)] = []
        var wallSegs:     [(SIMD3<Float>, SIMD3<Float>)] = []
        var chestSegs:    [(SIMD3<Float>, SIMD3<Float>)] = []
        var enemySegs:    [(SIMD3<Float>, SIMD3<Float>)] = []
        var doorSegs:     [(SIMD3<Float>, SIMD3<Float>)] = []
        var lockedDoorSegs: [(SIMD3<Float>, SIMD3<Float>)] = []
        var keyChestSegs: [(SIMD3<Float>, SIMD3<Float>)] = []
        var openedChestSegs: [(SIMD3<Float>, SIMD3<Float>)] = []
        var stairsUpSegs: [(SIMD3<Float>, SIMD3<Float>)] = []

        for r in 0..<rows {
            for c in 0..<cols {
                let tile = map.tiles[r][c]
                let revealed = tile.revealed
                let reachable = map.canMoveTo(row: r, col: c)
                let p = tileCenter(row: r, col: c)

                if tile.kind == .wall {
                    // Walls are obstacles, not floor. An unrevealed
                    // wall renders as ordinary fog so it doesn't leak
                    // map info; a revealed wall gets a filled amber
                    // block — solid fill reads as "impassable" more
                    // clearly than a hollow outline. Wireframe edges
                    // still go on top so the cube's silhouette is
                    // legible against the flat fill.
                    if revealed {
                        addSolidWallBlock(to: scene,
                                          center: SIMD3<Float>(p.x, 0.6, p.z))
                        addBoxEdges(to: &wallSegs,
                                     center: SIMD3<Float>(p.x, 0.6, p.z),
                                     size: SIMD3<Float>(0.94, 1.2, 0.94))
                    } else {
                        addBoxEdges(to: &fogSegs,
                                     center: SIMD3<Float>(p.x, 0.6, p.z),
                                     size: SIMD3<Float>(0.94, 1.2, 0.94))
                    }
                    continue
                }

                if revealed || reachable {
                    // Floor tile outline.
                    let h: Float = 0.5
                    let a = SIMD3<Float>(p.x - h, 0, p.z - h)
                    let b = SIMD3<Float>(p.x + h, 0, p.z - h)
                    let cc = SIMD3<Float>(p.x + h, 0, p.z + h)
                    let d = SIMD3<Float>(p.x - h, 0, p.z + h)
                    floorSegs.append((a, b))
                    floorSegs.append((b, cc))
                    floorSegs.append((cc, d))
                    floorSegs.append((d, a))
                } else {
                    // Unknown region: wireframe fog pillar.
                    addBoxEdges(to: &fogSegs,
                                 center: SIMD3<Float>(p.x, 0.6, p.z),
                                 size: SIMD3<Float>(0.94, 1.2, 0.94))
                }

                guard revealed else { continue }
                switch tile.kind {
                case .empty, .wall:
                    break
                case .chest:
                    addBoxEdges(to: &chestSegs,
                                 center: SIMD3<Float>(p.x, 0.18, p.z),
                                 size: SIMD3<Float>(0.52, 0.36, 0.4))
                case .openedChest:
                    // Spent: a flatter, dimmer husk so it reads as
                    // already-looted at a glance.
                    addBoxEdges(to: &openedChestSegs,
                                 center: SIMD3<Float>(p.x, 0.09, p.z),
                                 size: SIMD3<Float>(0.52, 0.18, 0.4))
                case .enemy:
                    addPyramidEdges(to: &enemySegs, base: p,
                                     baseSize: 0.52, height: 0.7)
                case .door:
                    addDoorEdges(to: &doorSegs, base: p)
                case .lockedDoor:
                    addDoorEdges(to: &lockedDoorSegs, base: p)
                case .keyChest:
                    addBoxEdges(to: &keyChestSegs,
                                 center: SIMD3<Float>(p.x, 0.18, p.z),
                                 size: SIMD3<Float>(0.52, 0.36, 0.4))
                case .stairsUp:
                    addDoorEdges(to: &stairsUpSegs, base: p)
                }
            }
        }

        let floorColor    = NSColor(calibratedRed: 0.20, green: 1.00, blue: 0.50, alpha: 1)
        let fogColor      = NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.00, alpha: 1)
        let wallColor     = NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.20, alpha: 1)
        let chestColor    = NSColor(calibratedRed: 0.65, green: 1.00, blue: 0.30, alpha: 1)
        let enemyColor    = NSColor(calibratedRed: 0.00, green: 0.95, blue: 1.00, alpha: 1)
        let doorColor     = NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.00, alpha: 1)
        let lockedDoorColor = NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.40, alpha: 1)
        let keyChestColor = NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.30, alpha: 1)
        let openedChestColor = NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.45, alpha: 1)
        let stairsUpColor = NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.80, alpha: 1)

        for (segs, color) in [
            (floorSegs,    floorColor),
            (fogSegs,      fogColor),
            (wallSegs,     wallColor),
            (chestSegs,    chestColor),
            (enemySegs,    enemyColor),
            (doorSegs,     doorColor),
            (lockedDoorSegs, lockedDoorColor),
            (keyChestSegs, keyChestColor),
            (openedChestSegs, openedChestColor),
            (stairsUpSegs, stairsUpColor),
        ] {
            guard let geom = buildLineGeometry(segments: segs, color: color) else { continue }
            let node = SCNNode(geometry: geom)
            node.name = contentTag
            scene.rootNode.addChildNode(node)
        }
    }

    // MARK: - Wireframe geometry helpers

    /// Build a `.line`-primitive SCNGeometry over a list of segment pairs.
    /// Returns nil when there's nothing to draw so callers can skip
    /// adding a useless node.
    static func buildLineGeometry(
        segments: [(SIMD3<Float>, SIMD3<Float>)],
        color: NSColor
    ) -> SCNGeometry? {
        guard !segments.isEmpty else { return nil }
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(segments.count * 2)
        var indices: [Int32] = []
        indices.reserveCapacity(segments.count * 2)
        for seg in segments {
            indices.append(Int32(verts.count))
            verts.append(seg.0)
            indices.append(Int32(verts.count))
            verts.append(seg.1)
        }
        let vertData = Data(bytes: verts,
                             count: MemoryLayout<SIMD3<Float>>.stride * verts.count)
        let src = SCNGeometrySource(
            data: vertData, semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride)

        let idxData = Data(bytes: indices,
                            count: MemoryLayout<Int32>.size * indices.count)
        let element = SCNGeometryElement(
            data: idxData,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size)

        let geom = SCNGeometry(sources: [src], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        geom.firstMaterial = m
        return geom
    }

    /// Translucent amber block for a revealed wall tile. The tint
    /// reads as a barrier without fully hiding what's behind it; the
    /// wireframe edges (added separately at a slightly larger size)
    /// sit on top via `renderingOrder = -1`, which forces the fill
    /// to draw before everything else so the bright outline renders
    /// over it.
    static func addSolidWallBlock(
        to scene: SCNScene, center: SIMD3<Float>
    ) {
        let box = SCNBox(width: 0.92, height: 1.18, length: 0.92,
                         chamferRadius: 0)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents  = NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.20, alpha: 1)
        m.emission.contents = NSColor(calibratedRed: 0.25, green: 0.10, blue: 0.02, alpha: 1)
        m.transparency = 0.22
        m.blendMode = .alpha
        m.isDoubleSided = false
        box.firstMaterial = m
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(center.x, center.y, center.z)
        node.renderingOrder = -1
        node.name = contentTag
        scene.rootNode.addChildNode(node)
    }

    static func addBoxEdges(
        to segments: inout [(SIMD3<Float>, SIMD3<Float>)],
        center: SIMD3<Float>, size: SIMD3<Float>
    ) {
        let hx = size.x / 2, hy = size.y / 2, hz = size.z / 2
        let c = center
        let corners: [SIMD3<Float>] = [
            SIMD3(c.x - hx, c.y - hy, c.z - hz),  // 0
            SIMD3(c.x + hx, c.y - hy, c.z - hz),  // 1
            SIMD3(c.x + hx, c.y - hy, c.z + hz),  // 2
            SIMD3(c.x - hx, c.y - hy, c.z + hz),  // 3
            SIMD3(c.x - hx, c.y + hy, c.z - hz),  // 4
            SIMD3(c.x + hx, c.y + hy, c.z - hz),  // 5
            SIMD3(c.x + hx, c.y + hy, c.z + hz),  // 6
            SIMD3(c.x - hx, c.y + hy, c.z + hz),  // 7
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),  // bottom rect
            (4, 5), (5, 6), (6, 7), (7, 4),  // top rect
            (0, 4), (1, 5), (2, 6), (3, 7),  // verticals
        ]
        for (a, b) in edges {
            segments.append((corners[a], corners[b]))
        }
    }

    private static func addPyramidEdges(
        to segments: inout [(SIMD3<Float>, SIMD3<Float>)],
        base: SIMD3<Float>, baseSize: Float, height: Float
    ) {
        let h = baseSize / 2
        let p0 = SIMD3<Float>(base.x - h, base.y, base.z - h)
        let p1 = SIMD3<Float>(base.x + h, base.y, base.z - h)
        let p2 = SIMD3<Float>(base.x + h, base.y, base.z + h)
        let p3 = SIMD3<Float>(base.x - h, base.y, base.z + h)
        let tip = SIMD3<Float>(base.x, base.y + height, base.z)
        segments.append((p0, p1))
        segments.append((p1, p2))
        segments.append((p2, p3))
        segments.append((p3, p0))
        segments.append((p0, tip))
        segments.append((p1, tip))
        segments.append((p2, tip))
        segments.append((p3, tip))
    }

    /// Door = tall portal frame at the tile center with a crossed
    /// inner brace, facing the +Z / -Z axis. Reads as a "way through"
    /// even at a glance.
    private static func addDoorEdges(
        to segments: inout [(SIMD3<Float>, SIMD3<Float>)],
        base: SIMD3<Float>
    ) {
        let halfW: Float = 0.32
        let height: Float = 1.05
        let yBase = base.y
        let yTop  = yBase + height
        let p0 = SIMD3<Float>(base.x - halfW, yBase, base.z)
        let p1 = SIMD3<Float>(base.x + halfW, yBase, base.z)
        let p2 = SIMD3<Float>(base.x + halfW, yTop,  base.z)
        let p3 = SIMD3<Float>(base.x - halfW, yTop,  base.z)
        segments.append((p0, p3))   // left jamb
        segments.append((p1, p2))   // right jamb
        segments.append((p3, p2))   // lintel
        segments.append((p0, p2))   // diagonal
        segments.append((p1, p3))   // diagonal
    }
}

/// Phantasy-Star-style first-person combat tableau. The enemy looms
/// in the middle of the view; a wireframe silhouette of the player's
/// upper body frames the bottom of the screen. Combat itself resolves
/// through the die-roll overlay the parent view layers on top of this
/// scene — this view is the *backdrop* for the fight, not its logic.
struct FightView3D: NSViewRepresentable {
    /// Bumped by the parent on every new battle. The coordinator
    /// compares against `lastEpoch` and resets the enemy node's
    /// scale/opacity so a previous battle's explosion doesn't bleed
    /// into the next encounter.
    var battleEpoch: Int = 0
    /// Set when the player kills the enemy. The coordinator notices
    /// the new timestamp and runs the wireframe-explode animation.
    var defeatedAt: Date? = nil
    /// Bumped each time the enemy starts a turn. The coordinator
    /// runs an eye-glow windup followed by a laser beam toward the
    /// camera. Damage / hit-impact are scheduled by the parent so
    /// they land on the visual beam fire.
    var attackAt: Date? = nil

    final class Coordinator {
        weak var enemyNode: SCNNode?
        weak var leftEyeGlow: SCNNode?
        weak var rightEyeGlow: SCNNode?
        weak var leftBeam: SCNNode?
        weak var rightBeam: SCNNode?
        var lastEpoch: Int = -1
        var lastDefeatTrigger: Date? = nil
        var lastAttackTrigger: Date? = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = false

        let scene = SCNScene()
        scene.background.contents = NSColor.black

        let camNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = 60
        cam.zNear = 0.05
        cam.zFar = 60
        camNode.camera = cam
        camNode.position = SCNVector3(0, 2.0, 3.5)
        camNode.eulerAngles = SCNVector3(-0.15, 0, 0)
        scene.rootNode.addChildNode(camNode)

        addFloorGrid(to: scene)
        context.coordinator.enemyNode = addEnemy(to: scene)
        addEyeWeapons(to: scene, coord: context.coordinator)
        addPlayerSilhouette(to: scene)

        view.scene = scene
        context.coordinator.lastEpoch = battleEpoch
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        let coord = context.coordinator
        // New battle: snap the enemy back to fresh pose.
        if battleEpoch != coord.lastEpoch {
            coord.lastEpoch = battleEpoch
            resetEnemy(coord.enemyNode)
            resetEyeWeapons(coord)
        }
        // Enemy defeated: animate the wireframe disintegration.
        if let trigger = defeatedAt, trigger != coord.lastDefeatTrigger {
            coord.lastDefeatTrigger = trigger
            explodeEnemy(coord.enemyNode)
        }
        // Enemy turn: windup + beam.
        if let trigger = attackAt, trigger != coord.lastAttackTrigger {
            coord.lastAttackTrigger = trigger
            fireEyeLaser(coord)
        }
    }

    /// Scale-up + fade-out the enemy node over ~0.5s — fits inside
    /// the existing 1.5s post-roll hold so the player sees the
    /// wireframe blow apart before the fight view fades.
    private func explodeEnemy(_ node: SCNNode?) {
        guard let node = node else { return }
        node.removeAllActions()
        let scaleUp = SCNAction.scale(to: 1.6, duration: 0.5)
        let fadeOut = SCNAction.fadeOut(duration: 0.5)
        let group = SCNAction.group([scaleUp, fadeOut])
        group.timingMode = .easeOut
        node.runAction(group)
    }

    private func resetEnemy(_ node: SCNNode?) {
        guard let node = node else { return }
        node.removeAllActions()
        node.scale = SCNVector3(1, 1, 1)
        node.opacity = 1
    }

    /// Eye positions on the shade's head — kept in sync with the bars
    /// drawn inside `addEnemy`. The beam target sits just in front of
    /// the camera (camera is at z=3.5) so the two beams visibly fly
    /// into the lens.
    private static let leftEyePos  = SCNVector3(-0.10, 1.60, 0.20)
    private static let rightEyePos = SCNVector3( 0.10, 1.60, 0.20)
    private static let beamTarget  = SCNVector3( 0.00, 1.85, 3.40)
    private static let laserColor  = NSColor(calibratedRed: 1.00,
                                              green: 0.20,
                                              blue:  0.28,
                                              alpha: 1.00)

    /// Build the windup-glow spheres and the laser beam lines. All
    /// four nodes start invisible; `fireEyeLaser` animates them.
    private func addEyeWeapons(to scene: SCNScene, coord: Coordinator) {
        coord.leftEyeGlow  = makeEyeGlow(at: Self.leftEyePos)
        coord.rightEyeGlow = makeEyeGlow(at: Self.rightEyePos)
        if let l = coord.leftEyeGlow  { scene.rootNode.addChildNode(l) }
        if let r = coord.rightEyeGlow { scene.rootNode.addChildNode(r) }

        coord.leftBeam  = makeBeam(from: Self.leftEyePos,  to: Self.beamTarget)
        coord.rightBeam = makeBeam(from: Self.rightEyePos, to: Self.beamTarget)
        if let l = coord.leftBeam  { scene.rootNode.addChildNode(l) }
        if let r = coord.rightBeam { scene.rootNode.addChildNode(r) }
    }

    private func makeEyeGlow(at p: SCNVector3) -> SCNNode {
        let sphere = SCNSphere(radius: 0.07)
        sphere.segmentCount = 12
        let mat = SCNMaterial()
        mat.diffuse.contents  = NSColor.black
        mat.emission.contents = Self.laserColor
        mat.lightingModel     = .constant
        sphere.firstMaterial  = mat
        let node = SCNNode(geometry: sphere)
        node.position = p
        node.opacity  = 0
        node.scale    = SCNVector3(0.4, 0.4, 0.4)
        return node
    }

    /// Thick laser beam built as an SCNCylinder. The cylinder lives
    /// inside a parent node anchored at the eye and rotated so its
    /// local +Y points at the target; the cylinder is offset along
    /// that axis so the parent's origin sits at the eye end of the
    /// beam. Animating `parent.scale` uniformly from 0 to 1 makes the
    /// beam visually extend out of the eye toward the camera while
    /// also "thickening" — gives the impression of a launched bolt.
    private func makeBeam(from a: SCNVector3, to b: SCNVector3) -> SCNNode? {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)
        guard length > 1e-4 else { return nil }
        let cyl = SCNCylinder(radius: 0.055, height: CGFloat(length))
        cyl.radialSegmentCount = 12
        let mat = SCNMaterial()
        mat.diffuse.contents  = NSColor.black
        mat.emission.contents = Self.laserColor
        mat.lightingModel     = .constant
        cyl.firstMaterial     = mat
        let geomNode = SCNNode(geometry: cyl)
        // Shift the cylinder so its base sits at the parent origin —
        // when the parent scales up, the beam grows outward from the
        // eye, not from the midpoint.
        geomNode.position = SCNVector3(0, length / 2, 0)

        let parent = SCNNode()
        parent.position = a
        // Rotate parent so local +Y aligns with (b - a). Default
        // cylinder axis is +Y, so this aims the beam at the target.
        let dir = simd_normalize(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
        let up  = SIMD3<Float>(0, 1, 0)
        let axis = simd_cross(up, dir)
        let dot  = simd_dot(up, dir)
        let axisLen = simd_length(axis)
        if axisLen > 1e-5 {
            let angle = acos(max(-1, min(1, dot)))
            let n = axis / axisLen
            parent.rotation = SCNVector4(CGFloat(n.x), CGFloat(n.y),
                                         CGFloat(n.z), CGFloat(angle))
        } else if dot < 0 {
            // dir == -Y: flip 180° around X.
            parent.rotation = SCNVector4(1, 0, 0, CGFloat.pi)
        }
        parent.addChildNode(geomNode)
        parent.opacity = 0
        parent.scale   = SCNVector3(0, 0, 0)
        return parent
    }

    /// Run the eye-glow windup followed by the laser shoot. Durations
    /// match `BattleView.enemyWindupSeconds` / `enemyBeamFade` so the
    /// damage + red flash schedule lines up with the visual beam.
    private func fireEyeLaser(_ coord: Coordinator) {
        let windup: Double = 0.55
        let beamFade: Double = 0.40

        // Glow: fade in + scale up during windup, hold while the beam
        // fires, then fade out as the beam dies.
        let glowIn = SCNAction.group([
            SCNAction.fadeIn(duration: windup),
            SCNAction.scale(to: 1.5, duration: windup)
        ])
        glowIn.timingMode = .easeIn
        let glowHold = SCNAction.wait(duration: 0.12)
        let glowOut  = SCNAction.group([
            SCNAction.fadeOut(duration: beamFade),
            SCNAction.scale(to: 0.4, duration: beamFade)
        ])
        glowOut.timingMode = .easeOut
        let glowSeq = SCNAction.sequence([glowIn, glowHold, glowOut])

        // Beam: invisible during windup, then SHOOT — uniform scale
        // 0→1 over a fast 90 ms grows the cylinder from the eye out
        // to the camera. Opacity flips on at the same instant so the
        // cylinder doesn't briefly appear at zero scale.
        let beamWait  = SCNAction.wait(duration: windup)
        let beamReset = SCNAction.run { node in
            node.opacity = 1
            node.scale   = SCNVector3(0, 0, 0)
        }
        let beamShoot = SCNAction.scale(to: 1.0, duration: 0.09)
        beamShoot.timingMode = .easeOut
        let beamHold = SCNAction.wait(duration: 0.10)
        let beamOff  = SCNAction.fadeOut(duration: beamFade - 0.19)
        let beamSeq  = SCNAction.sequence([beamWait, beamReset, beamShoot, beamHold, beamOff])

        // Restart on retrigger — `removeAllActions` so a quick second
        // turn doesn't compound onto a still-running animation.
        for n in [coord.leftEyeGlow, coord.rightEyeGlow] {
            n?.removeAllActions()
            n?.runAction(glowSeq)
        }
        for n in [coord.leftBeam, coord.rightBeam] {
            n?.removeAllActions()
            n?.runAction(beamSeq)
        }
    }

    /// Snap glow + beam state back to the hidden defaults. Called on
    /// a new battle so a partially-played laser from the previous
    /// encounter doesn't bleed into the next one.
    private func resetEyeWeapons(_ coord: Coordinator) {
        for n in [coord.leftEyeGlow, coord.rightEyeGlow] {
            n?.removeAllActions()
            n?.opacity = 0
            n?.scale   = SCNVector3(0.4, 0.4, 0.4)
        }
        for n in [coord.leftBeam, coord.rightBeam] {
            n?.removeAllActions()
            n?.opacity = 0
            n?.scale   = SCNVector3(0, 0, 0)
        }
    }

    /// Receding floor grid for spatial context. Tron green, matching
    /// the dungeon's floor color so the combat reads as "still inside
    /// the same world."
    private func addFloorGrid(to scene: SCNScene) {
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        let halfX: Float = 2.5
        let zNear: Float = -1.0
        let zFar:  Float = 3.5
        let step:  Float = 0.5
        var x = -halfX
        while x <= halfX + 0.001 {
            segs.append((SIMD3(x, 0, zNear), SIMD3(x, 0, zFar)))
            x += step
        }
        var z = zNear
        while z <= zFar + 0.001 {
            segs.append((SIMD3(-halfX, 0, z), SIMD3(halfX, 0, z)))
            z += step
        }
        let color = NSColor(calibratedRed: 0.20, green: 1.00, blue: 0.50, alpha: 1)
        if let g = DungeonView3D.buildLineGeometry(segments: segs, color: color) {
            scene.rootNode.addChildNode(SCNNode(geometry: g))
        }
    }

    /// Humanoid enemy wireframe at world origin, facing the camera.
    /// Cyan so it matches the dungeon's existing enemy color.
    /// Returns the node so the coordinator can animate it later.
    @discardableResult
    private func addEnemy(to scene: SCNScene) -> SCNNode? {
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        DungeonView3D.addBoxEdges(to: &segs,
                                   center: SIMD3(0, 1.55, 0),
                                   size: SIMD3(0.4, 0.4, 0.4))                // head
        segs.append((SIMD3(0, 1.35, 0), SIMD3(0, 1.25, 0)))                   // neck
        segs.append((SIMD3(-0.4, 1.25, 0), SIMD3(0.4, 1.25, 0)))              // shoulders
        segs.append((SIMD3(0, 1.25, 0), SIMD3(0, 0.65, 0)))                   // spine
        segs.append((SIMD3(-0.3, 0.65, 0), SIMD3(0.3, 0.65, 0)))              // hips
        segs.append((SIMD3(-0.4, 1.25, 0), SIMD3(-0.55, 0.75, 0)))            // L upper arm
        segs.append((SIMD3(-0.55, 0.75, 0), SIMD3(-0.5, 0.35, 0)))            // L forearm
        segs.append((SIMD3(0.4, 1.25, 0),  SIMD3(0.55, 0.75, 0)))             // R upper arm
        segs.append((SIMD3(0.55, 0.75, 0), SIMD3(0.5, 0.35, 0)))              // R forearm
        segs.append((SIMD3(-0.3, 0.65, 0), SIMD3(-0.25, 0.05, 0)))            // L leg
        segs.append((SIMD3(0.3, 0.65, 0),  SIMD3(0.25, 0.05, 0)))             // R leg
        // Glowing eyes — short bars on the front face of the head box.
        segs.append((SIMD3(-0.15, 1.6, 0.2), SIMD3(-0.05, 1.6, 0.2)))
        segs.append((SIMD3(0.05, 1.6, 0.2),  SIMD3(0.15, 1.6, 0.2)))
        let color = NSColor(calibratedRed: 0.00, green: 0.95, blue: 1.00, alpha: 1)
        guard let g = DungeonView3D.buildLineGeometry(segments: segs, color: color) else {
            return nil
        }
        let node = SCNNode(geometry: g)
        scene.rootNode.addChildNode(node)
        return node
    }

    /// The player's upper body from behind, parked between the camera
    /// and the enemy so it crops to "waist-up at the bottom of the
    /// screen." Green to match the dungeon floor / player palette,
    /// with a sword extending toward the enemy.
    private func addPlayerSilhouette(to scene: SCNScene) {
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        let z: Float = 2.5
        // Shoulders, torso outline, waist.
        segs.append((SIMD3(-0.65, 1.45, z), SIMD3(0.65, 1.45, z)))
        segs.append((SIMD3(-0.55, 1.45, z), SIMD3(-0.5, 0.7, z)))
        segs.append((SIMD3(0.55, 1.45, z),  SIMD3(0.5, 0.7, z)))
        segs.append((SIMD3(-0.5, 0.7, z),   SIMD3(0.5, 0.7, z)))
        // Neck.
        segs.append((SIMD3(-0.18, 1.45, z), SIMD3(-0.18, 1.6, z)))
        segs.append((SIMD3(0.18, 1.45, z),  SIMD3(0.18, 1.6, z)))
        // Back of head.
        DungeonView3D.addBoxEdges(to: &segs,
                                   center: SIMD3(0, 1.8, z),
                                   size: SIMD3(0.42, 0.4, 0.4))
        // Arms holding a sword extended toward the enemy.
        segs.append((SIMD3(-0.65, 1.45, z), SIMD3(-0.85, 1.2, z)))
        segs.append((SIMD3(-0.85, 1.2, z),  SIMD3(-0.18, 1.3, z - 0.4)))
        segs.append((SIMD3(0.65, 1.45, z),  SIMD3(0.85, 1.2, z)))
        segs.append((SIMD3(0.85, 1.2, z),   SIMD3(0.18, 1.3, z - 0.4)))
        // Sword: crossguard, then long blade pointing into the scene.
        segs.append((SIMD3(-0.18, 1.32, z - 0.4), SIMD3(0.18, 1.32, z - 0.4)))
        segs.append((SIMD3(0, 1.32, z - 0.4),     SIMD3(0, 1.32, z - 1.6)))
        let color = NSColor(calibratedRed: 0.20, green: 1.00, blue: 0.50, alpha: 1)
        if let g = DungeonView3D.buildLineGeometry(segments: segs, color: color) {
            scene.rootNode.addChildNode(SCNNode(geometry: g))
        }
    }
}

enum PendingRoll {
    case attack
    case flee
}

/// Combat stat block, shared by player and enemies. Stat range is
/// 1-20; the d20 you roll IS the attack roll, so stats act as
/// modifiers (D&D-flavored). Defense is split into physical and
/// magical; magic costs MP.
/// Single source of truth for every player-facing flavor term and
/// message. Re-theming (e.g. fantasy → Tron) is a *data* edit in this
/// one type — call sites stay structural. Values below are the
/// current fantasy wording, verbatim; change them, not the call
/// sites, when a theme swap lands. Duplicate keyboard/mouse discovery
/// lines now share one definition here (the only difference, the
/// input affordance, is the `advance` parameter, e.g. "Press space"
/// vs "Click again").
enum Lexicon {
    // MARK: World nouns
    static let world      = "dungeon"          // the overall space
    static let level      = "floor"            // one descent layer
    static let chest      = "treasure chest"
    static let chestShort = "chest"
    static let keyUpper   = "KEY"
    static let key        = "key"
    static let gate       = "stairwell"        // the locked descent point
    static let door       = "door"             // an ordinary descent door
    static let die        = "die"
    static let foeDefault = "enemy"            // generic, pre-identification
    static let foeShade   = "Shade"            // the only enemy type so far

    // MARK: Battle menu (must stay in sync with the confirm switch)
    static let menuFight  = "Fight"
    static let menuItem   = "Item"
    static let menuHack   = "Hack"
    static let menuFlee   = "Flee"
    static let fleeVerb   = "Flee"             // verb form in prose

    // MARK: Movement / discovery
    static func stepEmpty() -> String { "You step into an empty space." }
    static func stepChest() -> String { "You find a \(chest)." }
    static func stepFoe()   -> String { "You spot an \(foeDefault)." }
    static func stepDoorDown(_ advance: String) -> String {
        "You find a \(door) leading down. \(advance) to descend."
    }
    static func stepStairsUp(_ advance: String) -> String {
        "Stairs lead back up. \(advance) to ascend."
    }
    static func keyFound() -> String {
        "You pry open a \(chestShort) — a heavy \(keyUpper) rests inside. The sealed \(gate) will open now."
    }
    static func lockedGate(hasKey: Bool, advance: String) -> String {
        hasKey
            ? "A sealed \(gate). Your \(key) fits — \(advance.lowercased()) to descend."
            : "A sealed \(gate). You need this \(level)'s \(key) to open it."
    }

    // MARK: Stairs / floor transitions
    static func gateSealed() -> String {
        "The \(gate) is sealed. Find this \(level)'s \(key) first."
    }
    static func keyFits()   -> String { "Your \(key) fits. The \(gate) grinds open." }
    static func worldEnds() -> String { "The \(door) refuses to open. The \(world) ends here." }
    static func descend(to n: Int) -> String { "You descend to \(level) \(n)." }
    static func ascend(to n: Int)  -> String { "You ascend to \(level) \(n)." }
    static func wake() -> String { "You wake. The \(world) resets to its first \(level)." }

    // MARK: Battle flow
    static func battleStart(_ foe: String) -> String {
        "\(foe.uppercased()) bars your path. Battle!"
    }
    static func rollPrompt(strike: Bool) -> String {
        strike
            ? "ROLL THE \(die.uppercased()) TO STRIKE\nHOLD SPACE — RELEASE TO THROW"
            : "ROLL THE \(die.uppercased()) TO \(fleeVerb.uppercased())\nHOLD SPACE — RELEASE TO THROW"
    }
    static func notAvailable(_ name: String) -> String {
        "\(name.uppercased()) is not yet available."
    }
    static func hackSpent() -> String {
        "No hack charges left this fight."
    }
    static func readyStrike() -> String {
        "You ready a strike. Roll the \(die) — hold SPACE, release to throw."
    }
    static func readyFlee() -> String {
        "You move to flee. Roll the \(die) — hold SPACE, release to throw."
    }
    static func foeFaster(_ foe: String, foeSpd: Int, playerSpd: Int) -> String {
        "\(foe.uppercased()) is faster — it strikes first! (SPD \(foeSpd) vs \(playerSpd))"
    }
    static func critMissStrike() -> String {
        "CRITICAL MISS! You roll 1. Your strike goes wide."
    }
    static func strikeHit(roll: Int, foe: String, damage: Int,
                          str: Int, pdf: Int, crit: Bool) -> String {
        let prefix  = crit ? "CRITICAL HIT! " : ""
        let critTag = crit ? " + 2 crit" : ""
        return "\(prefix)You roll \(roll). You strike \(foe) for \(damage) damage. (STR \(str) + \(roll) − PDF \(pdf)\(critTag))"
    }
    static func foeCollapses(_ foe: String) -> String {
        "\(foe.uppercased()) collapses. The path is clear."
    }
    static func fleeCritFail(_ foe: String) -> String {
        "CRITICAL FAIL — \(foe) catches you. You take 3 damage."
    }
    static func fleeFail(roll: Int) -> String {
        "You roll \(roll). You fail to escape and take 1 damage."
    }
    static func fleeEscape(roll: Int) -> String {
        "You roll \(roll). You break away and escape!"
    }
    static func fleeCritSuccess(_ foe: String) -> String {
        "CRITICAL SUCCESS — A parting blow lands! You escape and \(foe) takes 1 damage."
    }
    static func fleeUnclear(roll: Int) -> String {
        "You roll \(roll). The result is unclear."
    }
    static func fleeGuaranteed(_ foe: String) -> String {
        "You slip away clean — \(foe) never had a chance. (Escape Artist)"
    }
    static func lifestealTick(_ hp: Int) -> String {
        "The strike feeds you — +\(hp) HP. (Lifesteal)"
    }

    // MARK: Hack
    static func hackReady() -> String {
        "You jack in. Terminal handshake initialised."
    }
    static func hackSuccess(foe: String, damage: Int,
                            mag: Int, score: Int, mdf: Int) -> String {
        "EXEC ▸ payload lands on \(foe) for \(damage) damage. (MAG \(mag) + \(score) − MDF \(mdf))"
    }
    static func hackFailure(_ foe: String) -> String {
        "Connection dropped. \(foe) lashes out unopposed."
    }
    static func foeMisses(_ foe: String) -> String {
        "\(foe) fires — the beam whips past you. (rolls 1)"
    }
    static func foeHit(_ foe: String, damage: Int, str: Int,
                       roll: Int, pdf: Int, crit: Bool) -> String {
        let prefix  = crit ? "CRITICAL HIT! " : ""
        let critTag = crit ? " + 2 crit" : ""
        return "\(prefix)\(foe)'s eye-beam burns you for \(damage). (STR \(str) + \(roll) − PDF \(pdf)\(critTag))"
    }
    static func defeated(_ foe: String) -> String {
        "You collapse before \(foe). Defeated."
    }

    // MARK: Die-roll callouts
    static func rolledDie()           -> String { "YOU ROLLED THE \(die.uppercased())" }
    static func rolledFace(_ f: Int)  -> String { "YOU ROLLED A \(f)" }

    // MARK: Gear item names
    // Tron-flavored procedural names for generated gear. Names only —
    // the stats live on GearItem. Swap these pools (or the join) when
    // the real re-theme lands; everything else stays structural.
    private static let itemPrefixes = [
        "Cracked", "Overclocked", "Encrypted", "Glitched", "Recursive",
        "Quantum", "Phantom", "Null", "Prismatic", "Corrupted",
    ]
    private static let itemCores = [
        "Cipher", "Vector", "Daemon", "Lattice", "Shard",
        "Protocol", "Fragment", "Sigil", "Kernel", "Echo",
    ]
    private static let itemForms = [
        "Disc", "Module", "Routine", "Relic", "Construct",
        "Core", "Subroutine", "Token", "Array", "Loop",
    ]
    static func randomItem() -> String {
        let p = itemPrefixes.randomElement() ?? "Cracked"
        let c = itemCores.randomElement() ?? "Cipher"
        let f = itemForms.randomElement() ?? "Disc"
        return "\(p) \(c) \(f)"
    }
    // MARK: Chest / gear actions
    static func chestHere(_ advance: String) -> String {
        "A \(chestShort) sits here. \(advance) to open it — or leave it."
    }
    static func chestOpened(_ name: String, summary: String) -> String {
        "You open the \(chestShort): \(name) — \(summary). Stowed in your pack."
    }
    static func chestSpent() -> String { "An opened \(chestShort), already emptied." }
    static func backpackFull(_ cap: Int) -> String {
        "Your pack is full (\(cap)/\(cap)). Manage gear before taking more."
    }
    static func equipped(_ name: String, slot: String) -> String {
        "Equipped \(name) (\(slot))."
    }
    static func unequipped(_ name: String) -> String { "Stowed \(name)." }
    static func discarded(_ name: String) -> String { "Discarded \(name)." }

    // MARK: Demo win screen
    static let winTitle    = "DEMO CLEAR"
    static let winSubtitle = "PRESS  SPACE  TO  RUN  IT  AGAIN"
    static func winHaul(_ count: Int) -> String {
        count == 0
            ? "You escaped the \(world) empty-handed."
            : "You escaped the \(world) with \(count) recovered:"
    }
}

struct Stats {
    var hp: Int
    var maxHP: Int
    var mp: Int
    var maxMP: Int
    var str: Int     // physical attack
    var spd: Int     // turn order / dodge
    var physDef: Int
    var mag: Int     // magic attack
    var magDef: Int
}

// MARK: - Gear system (locked design — see project memory)

/// The three equip slots. Each accepts exactly one item; finding an
/// upgrade is the power-fantasy axis, not hoarding.
enum GearSlot: String, CaseIterable {
    case weapon, armor, trinket
    var label: String {
        switch self {
        case .weapon:  return "Weapon"
        case .armor:   return "Armor"
        case .trinket: return "Trinket"
        }
    }
}

/// Rare deep-floor effects. Most gear is flat stat bumps; a `special`
/// is the chunky standout on scarce pieces. Kept small and combat-
/// hookable (no MP/magic specials — magic isn't wired yet).
enum GearSpecial: String {
    case none
    case keenEdge        // crit on a roll of 5 OR 6, not just 6
    case lifesteal       // heal 2 HP whenever your strike deals damage
    case guaranteedFlee  // flee always succeeds (no damage taken)
    case extraHack       // +1 Hack charge per battle (stacks across slots)

    var blurb: String {
        switch self {
        case .none:           return ""
        case .keenEdge:       return "Keen Edge (crit on 5-6)"
        case .lifesteal:      return "Lifesteal (+2 HP on hit)"
        case .guaranteedFlee: return "Escape Artist (flee always works)"
        case .extraHack:      return "Backdoor (+1 Hack/battle)"
        }
    }
}

/// One gear piece. Effects are flat, chunky stat bumps (benchmarked
/// so a single weapon is a *felt* swing against a floor-1 Shade) plus
/// an optional rare special. No stats live here that aren't opt-in.
struct GearItem: Identifiable {
    let id = UUID()
    var name: String
    var slot: GearSlot
    var dStr = 0
    var dSpd = 0
    var dPhysDef = 0
    var dMag = 0
    var dMagDef = 0
    var dMaxHP = 0
    var dMaxMP = 0
    var special: GearSpecial = .none

    /// Compact "+2 STR · +4 HP · Lifesteal"-style readout for menus.
    var summary: String {
        var parts: [String] = []
        if dStr     != 0 { parts.append("\(signed(dStr)) STR") }
        if dSpd     != 0 { parts.append("\(signed(dSpd)) SPD") }
        if dPhysDef != 0 { parts.append("\(signed(dPhysDef)) PDF") }
        if dMag     != 0 { parts.append("\(signed(dMag)) MAG") }
        if dMagDef  != 0 { parts.append("\(signed(dMagDef)) MDF") }
        if dMaxHP   != 0 { parts.append("\(signed(dMaxHP)) HP") }
        if dMaxMP   != 0 { parts.append("\(signed(dMaxMP)) MP") }
        if special != .none { parts.append(special.blurb) }
        return parts.isEmpty ? "(no effect)" : parts.joined(separator: " · ")
    }

    private func signed(_ v: Int) -> String { v >= 0 ? "+\(v)" : "\(v)" }

    /// Depth-scaled roll. Shallow floors give small single-stat bumps;
    /// deeper floors give bigger bumps and a rising chance of a rare
    /// special. Magnitudes stay chunky against the 1-20 stat range —
    /// every point is a felt swing, so the ceiling is deliberately low.
    static func roll(floor: Int) -> GearItem {
        let slot = GearSlot.allCases.randomElement() ?? .weapon
        // Band: ~+1 per 2 floors of headroom, capped so a 5-floor
        // demo tops out around +3-4 on a primary stat.
        let band = max(1, min(4, 1 + floor / 2))
        let lo = max(1, band - 1)
        func bump() -> Int { Int.random(in: lo...(band + 1)) }

        var item = GearItem(name: Lexicon.randomItem(), slot: slot)
        switch slot {
        case .weapon:
            // Offense piece: STR primary, occasional MAG flavor.
            if Bool.random() { item.dStr = bump() }
            else             { item.dMag = bump() }
            if item.dStr == 0 && item.dMag == 0 { item.dStr = bump() }
        case .armor:
            // Survivability: a defense plus a chunk of HP.
            if Bool.random() { item.dPhysDef = bump() } else { item.dMagDef = bump() }
            item.dMaxHP = bump() + 2
        case .trinket:
            // Utility: SPD / MP, and the home of most specials.
            if Bool.random() { item.dSpd = bump() } else { item.dMaxMP = bump() + 1 }
        }
        // Rare special, weighted by depth. ~0% floor 1 → ~40% floor 5+.
        let specialChance = Double(max(0, floor - 1)) * 0.10
        if Double.random(in: 0..<1) < specialChance {
            item.special = [.keenEdge, .lifesteal, .guaranteedFlee, .extraHack].randomElement() ?? .none
        }
        return item
    }
}

/// Per-type enemy stat baselines. Add cases as new enemies arrive;
/// `baselineStats(floor:)` mixes in a small depth bump so the same
/// enemy at floor 30 hits harder than at floor 1 without needing a
/// per-floor table.
enum EnemyType {
    case shade

    var displayName: String {
        switch self {
        case .shade: return Lexicon.foeShade
        }
    }

    func baselineStats(floor: Int) -> Stats {
        let bump = max(0, (floor - 1) / 3)
        switch self {
        case .shade:
            return Stats(
                hp: 8 + bump, maxHP: 8 + bump,
                mp: 4 + bump, maxMP: 4 + bump,
                str: 4 + bump, spd: 6 + bump,
                physDef: 3 + bump, mag: 6 + bump, magDef: 3 + bump
            )
        }
    }
}

struct BattleMenuOption {
    let name: String
    let enabled: Bool
}

/// Debug-only player stat block, sibling to `DebugEnemyStatsView`.
/// Green accent so it visually pairs with the green player HP bar in
/// the BattleHUD. Not intended to ship.
struct DebugPlayerStatsView: View {
    let stats: Stats

    private static let accent = Color(red: 0.30, green: 0.95, blue: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DEBUG · HERO")
                .foregroundColor(Self.accent)
            Divider().background(Color.white.opacity(0.2))
            statLine("HP",  cur: stats.hp,  max: stats.maxHP)
            statLine("MP",  cur: stats.mp,  max: stats.maxMP)
            statLine("STR", value: stats.str)
            statLine("SPD", value: stats.spd)
            statLine("PDF", value: stats.physDef)
            statLine("MAG", value: stats.mag)
            statLine("MDF", value: stats.magDef)
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .foregroundColor(Color(white: 0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Self.accent.opacity(0.45), lineWidth: 1)
        )
    }

    private func statLine(_ label: String, cur: Int, max: Int) -> some View {
        Text("\(label)  \(cur)/\(max)")
    }
    private func statLine(_ label: String, value: Int) -> some View {
        Text("\(label)  \(value)")
    }
}

/// Debug-only overlay listing the enemy's full stat block. Lives in
/// the upper-right of the battle view so we can sanity-check stat
/// scaling and damage formulas while tuning. Not intended to ship.
struct DebugEnemyStatsView: View {
    let name: String
    let stats: Stats
    let floor: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DEBUG · F\(floor)")
                .foregroundColor(Color(red: 1.0, green: 0.85, blue: 0.30))
            Text(name.uppercased())
                .foregroundColor(.white)
            Divider().background(Color.white.opacity(0.2))
            statLine("HP",  cur: stats.hp,  max: stats.maxHP)
            statLine("MP",  cur: stats.mp,  max: stats.maxMP)
            statLine("STR", value: stats.str)
            statLine("SPD", value: stats.spd)
            statLine("PDF", value: stats.physDef)
            statLine("MAG", value: stats.mag)
            statLine("MDF", value: stats.magDef)
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .foregroundColor(Color(white: 0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(red: 1.0, green: 0.85, blue: 0.30).opacity(0.45), lineWidth: 1)
        )
    }

    private func statLine(_ label: String, cur: Int, max: Int) -> some View {
        Text("\(label)  \(cur)/\(max)")
    }
    private func statLine(_ label: String, value: Int) -> some View {
        Text("\(label)  \(value)")
    }
}

/// Fight-start sting: the screen shatters into a grid of randomly
/// colored neon cells, the word ENGAGE flashes in the middle, then
/// the cells dissolve back out to reveal the fight view. Runs entirely
/// off a `TimelineView` driving a single `Canvas` draw so 600+ cells
/// stay cheap. Time-driven (not state-driven) so the animation is
/// deterministic regardless of view rebuilds.
struct BattleTransitionView: View {
    let startedAt: Date

    /// Phase durations (seconds). Tuning constants — feel free to
    /// nudge for pacing.
    static let shatterDuration: Double = 0.32
    static let holdDuration: Double = 0.55
    static let dissolveDuration: Double = 0.42
    static var totalDuration: Double {
        shatterDuration + holdDuration + dissolveDuration
    }

    private static let cols = 32
    private static let rows = 18
    private static let cellCount = cols * rows

    private static let palette: [Color] = [
        Color(red: 0.20, green: 1.00, blue: 0.50),  // floor green
        Color(red: 0.00, green: 0.95, blue: 1.00),  // enemy cyan
        Color(red: 1.00, green: 0.55, blue: 0.20),  // wall amber
        Color(red: 0.45, green: 0.80, blue: 1.00),  // door blue
        Color(red: 0.95, green: 0.30, blue: 0.30),  // hp red
        Color(white: 0.04),
        Color(white: 0.04),                          // weight black higher so the screen doesn't look like confetti
    ]

    /// Per-cell stagger (0…1) and color. Lives in @State so the
    /// random pattern is generated *once* when the view appears and
    /// stays stable across the TimelineView re-renders that drive
    /// the animation. If these were stored as `let` properties on the
    /// struct, SwiftUI would re-init the view (and re-roll the
    /// random values) on every parent body eval, turning the shatter
    /// into incoherent flicker.
    @State private var cellDelays: [Double] = (0..<BattleTransitionView.cellCount)
        .map { _ in Double.random(in: 0...0.85) }
    @State private var cellColors: [Color] = (0..<BattleTransitionView.cellCount)
        .map { _ in BattleTransitionView.palette.randomElement() ?? .black }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            ZStack {
                Canvas { ctx, size in
                    let cellW = size.width / Double(Self.cols)
                    let cellH = size.height / Double(Self.rows)
                    for i in 0..<Self.cellCount {
                        let opacity = cellOpacity(elapsed: elapsed, delay: cellDelays[i])
                        guard opacity > 0.01 else { continue }
                        let r = i / Self.cols
                        let c = i % Self.cols
                        let rect = CGRect(x: Double(c) * cellW,
                                          y: Double(r) * cellH,
                                          width: cellW, height: cellH)
                        ctx.fill(Path(rect),
                                 with: .color(cellColors[i].opacity(opacity)))
                    }
                }
                Text("ENGAGE")
                    .font(.system(size: 96, weight: .black, design: .monospaced))
                    .kerning(8)
                    .foregroundColor(Color(red: 1.00, green: 0.95, blue: 0.40))
                    .shadow(color: Color(red: 1, green: 0.55, blue: 0).opacity(0.85),
                            radius: 16)
                    .opacity(engageOpacity(elapsed: elapsed))
            }
        }
    }

    private func cellOpacity(elapsed: Double, delay: Double) -> Double {
        let shatterEnd = Self.shatterDuration
        let holdEnd = shatterEnd + Self.holdDuration
        let dissolveEnd = holdEnd + Self.dissolveDuration
        if elapsed < 0 { return 0 }
        if elapsed < shatterEnd {
            // Cells pop in over a fraction of the shatter window
            // staggered by their random delay.
            let cellStart = delay * Self.shatterDuration * 0.55
            let cellElapsed = elapsed - cellStart
            if cellElapsed <= 0 { return 0 }
            let fadeIn = Self.shatterDuration * 0.45
            return min(1, cellElapsed / fadeIn)
        }
        if elapsed < holdEnd { return 1 }
        if elapsed < dissolveEnd {
            let cellStart = delay * Self.dissolveDuration * 0.55
            let cellElapsed = elapsed - holdEnd - cellStart
            if cellElapsed <= 0 { return 1 }
            let fadeOut = Self.dissolveDuration * 0.45
            return max(0, 1 - cellElapsed / fadeOut)
        }
        return 0
    }

    private func engageOpacity(elapsed: Double) -> Double {
        let shatterEnd = Self.shatterDuration
        let dissolveEnd = shatterEnd + Self.holdDuration + Self.dissolveDuration
        if elapsed < shatterEnd { return 0 }
        let fadeIn: Double = 0.10
        if elapsed < shatterEnd + fadeIn {
            return (elapsed - shatterEnd) / fadeIn
        }
        let fadeOutStart = dissolveEnd - 0.18
        if elapsed < fadeOutStart { return 1 }
        if elapsed < dissolveEnd {
            return max(0, 1 - (elapsed - fadeOutStart) / 0.18)
        }
        return 0
    }
}

/// Death sting: the screen shatters into red-skewed cells and stays
/// there as a backdrop for the GAME OVER readout. Mirrors
/// `BattleTransitionView` but skips the dissolve phase — the cells
/// hold until the player presses SPACE and the parent clears
/// `gameOverStart`.
struct GameOverView: View {
    let startedAt: Date

    /// How long the cells take to fully pop in. Slightly slower than
    /// the ENGAGE shatter so the death beat feels heavier.
    static let shatterDuration: Double = 0.45
    /// Delay after the cells finish before the text fades in.
    static let textHoldDelay: Double = 0.10
    static let textFadeIn: Double = 0.40

    private static let cols = 32
    private static let rows = 18
    private static let cellCount = cols * rows

    /// Red-and-black heavy palette so the field reads as somber/death
    /// rather than the festival-colored ENGAGE intro.
    private static let palette: [Color] = [
        Color(red: 0.95, green: 0.25, blue: 0.30),
        Color(red: 1.00, green: 0.15, blue: 0.20),
        Color(red: 0.55, green: 0.10, blue: 0.15),
        Color(red: 0.30, green: 0.05, blue: 0.10),
        Color(white: 0.04),
        Color(white: 0.04),
        Color(white: 0.04),
    ]

    @State private var cellDelays: [Double] = (0..<GameOverView.cellCount)
        .map { _ in Double.random(in: 0...0.85) }
    @State private var cellColors: [Color] = (0..<GameOverView.cellCount)
        .map { _ in GameOverView.palette.randomElement() ?? .black }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            ZStack {
                Canvas { ctx, size in
                    let cellW = size.width / Double(Self.cols)
                    let cellH = size.height / Double(Self.rows)
                    for i in 0..<Self.cellCount {
                        let opacity = cellOpacity(elapsed: elapsed,
                                                   delay: cellDelays[i])
                        guard opacity > 0.01 else { continue }
                        let r = i / Self.cols
                        let c = i % Self.cols
                        let rect = CGRect(x: Double(c) * cellW,
                                          y: Double(r) * cellH,
                                          width: cellW, height: cellH)
                        ctx.fill(Path(rect),
                                 with: .color(cellColors[i].opacity(opacity)))
                    }
                }
                VStack(spacing: 32) {
                    Text("GAME OVER")
                        .font(.system(size: 104, weight: .black, design: .monospaced))
                        .kerning(10)
                        .foregroundColor(Color(red: 1.00, green: 0.95, blue: 0.95))
                        .shadow(color: Color(red: 1.00, green: 0.20, blue: 0.20).opacity(0.9),
                                radius: 24)
                    Text("PRESS  SPACE  TO  TRY  AGAIN")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .kerning(4)
                        .foregroundColor(Color(red: 1.00, green: 0.85, blue: 0.80))
                }
                .opacity(textOpacity(elapsed: elapsed))
            }
        }
    }

    private func cellOpacity(elapsed: Double, delay: Double) -> Double {
        if elapsed < 0 { return 0 }
        let cellStart = delay * Self.shatterDuration * 0.55
        let cellElapsed = elapsed - cellStart
        if cellElapsed <= 0 { return 0 }
        let fadeIn = Self.shatterDuration * 0.45
        return min(1, cellElapsed / fadeIn)
    }

    private func textOpacity(elapsed: Double) -> Double {
        let textStart = Self.shatterDuration + Self.textHoldDelay
        if elapsed < textStart { return 0 }
        let progress = (elapsed - textStart) / Self.textFadeIn
        return min(1, max(0, progress))
    }
}

/// DEMO win screen. Same shatter-in cell field as `GameOverView` so
/// the two outros read as a matched pair, but with a Tron-cyan
/// palette and a list of the run's collected placeholder loot.
/// Temporary — replace when real progression / a real end screen
/// lands.
struct WinView: View {
    let startedAt: Date
    let items: [GearItem]

    static let shatterDuration: Double = 0.45
    static let textHoldDelay: Double = 0.10
    static let textFadeIn: Double = 0.40

    private static let cols = 32
    private static let rows = 18
    private static let cellCount = cols * rows

    /// Cyan / electric-blue heavy palette — the celebratory inverse
    /// of GameOver's red, and a preview of the Tron re-theme.
    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.95, blue: 1.00),
        Color(red: 0.15, green: 0.75, blue: 1.00),
        Color(red: 0.10, green: 0.45, blue: 0.75),
        Color(red: 0.05, green: 0.20, blue: 0.35),
        Color(white: 0.04),
        Color(white: 0.04),
        Color(white: 0.04),
    ]

    @State private var cellDelays: [Double] = (0..<WinView.cellCount)
        .map { _ in Double.random(in: 0...0.85) }
    @State private var cellColors: [Color] = (0..<WinView.cellCount)
        .map { _ in WinView.palette.randomElement() ?? .black }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            ZStack {
                Canvas { ctx, size in
                    let cellW = size.width / Double(Self.cols)
                    let cellH = size.height / Double(Self.rows)
                    for i in 0..<Self.cellCount {
                        let opacity = cellOpacity(elapsed: elapsed,
                                                   delay: cellDelays[i])
                        guard opacity > 0.01 else { continue }
                        let r = i / Self.cols
                        let c = i % Self.cols
                        let rect = CGRect(x: Double(c) * cellW,
                                          y: Double(r) * cellH,
                                          width: cellW, height: cellH)
                        ctx.fill(Path(rect),
                                 with: .color(cellColors[i].opacity(opacity)))
                    }
                }
                VStack(spacing: 28) {
                    Text(Lexicon.winTitle)
                        .font(.system(size: 104, weight: .black, design: .monospaced))
                        .kerning(10)
                        .foregroundColor(Color(red: 0.92, green: 0.99, blue: 1.00))
                        .shadow(color: Color(red: 0.20, green: 0.85, blue: 1.00).opacity(0.9),
                                radius: 24)
                    VStack(spacing: 8) {
                        Text(Lexicon.winHaul(items.count))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .kerning(2)
                            .foregroundColor(Color(red: 0.80, green: 0.95, blue: 1.00))
                        ForEach(items) { item in
                            Text("• \(item.name) — \(item.summary)")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(red: 0.60, green: 0.90, blue: 1.00))
                        }
                    }
                    Text(Lexicon.winSubtitle)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .kerning(4)
                        .foregroundColor(Color(red: 0.75, green: 0.92, blue: 1.00))
                        .padding(.top, 8)
                }
                .opacity(textOpacity(elapsed: elapsed))
            }
        }
    }

    private func cellOpacity(elapsed: Double, delay: Double) -> Double {
        if elapsed < 0 { return 0 }
        let cellStart = delay * Self.shatterDuration * 0.55
        let cellElapsed = elapsed - cellStart
        if cellElapsed <= 0 { return 0 }
        let fadeIn = Self.shatterDuration * 0.45
        return min(1, cellElapsed / fadeIn)
    }

    private func textOpacity(elapsed: Double) -> Double {
        let textStart = Self.shatterDuration + Self.textHoldDelay
        if elapsed < textStart { return 0 }
        let progress = (elapsed - textStart) / Self.textFadeIn
        return min(1, max(0, progress))
    }
}

/// Inventory / equip overlay. Presentation-only — the parent owns
/// all state and mutation; this just draws the three slots, the
/// backpack, the live base→effective stat readout, and the cursor.
/// Cursor index is flat: slots first (in `slotOrder`), then backpack.
struct InventoryView: View {
    let slotOrder: [GearSlot]
    let equipped: [GearSlot: GearItem]
    let backpack: [GearItem]
    let selection: Int
    let base: Stats
    let effective: Stats
    let cap: Int

    private static let accent = Color(red: 0.30, green: 0.95, blue: 1.00)
    private static let dim = Color(white: 0.60)

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("GEAR")
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .kerning(8)
                    .foregroundColor(Self.accent)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(slotOrder.enumerated()), id: \.offset) { i, slot in
                        row(label: slot.label.uppercased(),
                            item: equipped[slot],
                            emptyText: "— empty —",
                            selected: selection == i)
                    }
                }

                Divider().background(Color.white.opacity(0.25))

                Text("PACK  \(backpack.count)/\(cap)")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Self.dim)
                VStack(alignment: .leading, spacing: 5) {
                    if backpack.isEmpty {
                        Text("(empty — open chests to fill it)")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(Self.dim)
                    } else {
                        ForEach(Array(backpack.enumerated()), id: \.element.id) { i, item in
                            row(label: nil,
                                item: item,
                                emptyText: "",
                                selected: selection == slotOrder.count + i)
                        }
                    }
                }

                Divider().background(Color.white.opacity(0.25))

                statLine
                Text("↑↓ select · ⏎ equip/stow · X discard · I close")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Self.dim)
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Color(white: 0.06))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Self.accent.opacity(0.5), lineWidth: 1))
            .cornerRadius(6)
        }
    }

    private func row(label: String?, item: GearItem?,
                     emptyText: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(selected ? "▶" : " ")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(Self.accent)
            if let label {
                Text(label)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Self.dim)
                    .frame(width: 84, alignment: .leading)
            }
            if let item {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text(item.summary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Self.accent.opacity(0.85))
            } else {
                Text(emptyText)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Self.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(selected ? Self.accent.opacity(0.16) : Color.clear)
        .cornerRadius(4)
    }

    private var statLine: some View {
        HStack(spacing: 14) {
            delta("STR", base.str, effective.str)
            delta("SPD", base.spd, effective.spd)
            delta("PDF", base.physDef, effective.physDef)
            delta("MDF", base.magDef, effective.magDef)
            delta("HP",  base.maxHP, effective.maxHP)
        }
    }

    private func delta(_ name: String, _ b: Int, _ e: Int) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Self.dim)
            Text(e == b ? "\(b)" : "\(b)→\(e)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(e > b ? Self.accent
                                       : (e < b ? Color(red: 1, green: 0.5, blue: 0.4)
                                                : .white))
        }
    }
}

/// Phantasy-Star-style combat readout: enemy strip at the top, player
/// strip + action menu at the bottom, both in the same monospaced
/// font as the game text log so the screen reads as one piece. All
/// state is passed in — this view is presentation-only.
struct BattleHUD: View {
    let enemyName: String
    let enemyHP: Int
    let enemyMaxHP: Int
    let playerHP: Int
    let playerMaxHP: Int
    let menu: [BattleMenuOption]
    let menuIndex: Int
    let awaitingRoll: Bool
    let rollPrompt: String
    let resolvingRoll: Bool
    let rollValue: Int?

    private static let barWidth = 20
    private static let enemyColor = Color(red: 0.95, green: 0.35, blue: 0.35)
    private static let playerColor = Color(red: 0.30, green: 0.95, blue: 0.55)
    private static let selectColor = Color(red: 1.00, green: 0.95, blue: 0.40)

    var body: some View {
        VStack(spacing: 0) {
            stripPanel {
                Text(enemyName.uppercased())
                    .foregroundColor(.white)
                hpLine(current: enemyHP, max: enemyMaxHP, color: Self.enemyColor)
            }
            Spacer()
            stripPanel {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HERO")
                            .foregroundColor(.white)
                        hpLine(current: playerHP, max: playerMaxHP, color: Self.playerColor)
                    }
                    Spacer()
                    if resolvingRoll {
                        Text(rollValue.map { "ROLLED \($0)" } ?? "ROLLED")
                            .foregroundColor(Self.selectColor)
                    } else if awaitingRoll {
                        Text(rollPrompt)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(Self.selectColor)
                    } else {
                        menuView
                    }
                }
            }
        }
        .font(.system(.title3, design: .monospaced).weight(.semibold))
        .padding(20)
    }

    private var menuView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(menu.enumerated()), id: \.offset) { idx, opt in
                let selected = idx == menuIndex
                HStack(spacing: 6) {
                    Text(selected ? "►" : " ")
                        .foregroundColor(Self.selectColor)
                    Text(opt.name.uppercased())
                        .foregroundColor(color(for: opt, selected: selected))
                }
            }
        }
    }

    private func color(for opt: BattleMenuOption, selected: Bool) -> Color {
        if !opt.enabled { return Color(white: 0.4) }
        return selected ? Self.selectColor : .white
    }

    @ViewBuilder
    private func stripPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.65),
                     in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private func hpLine(current: Int, max: Int, color: Color) -> some View {
        let bars = Self.barWidth
        let denom = Swift.max(max, 1)
        let filled = Swift.max(0, Swift.min(bars, Int(Double(bars) * Double(current) / Double(denom))))
        let empty = bars - filled
        let bar = "[" + String(repeating: "█", count: filled)
                      + String(repeating: "░", count: empty) + "]"
        return HStack(spacing: 10) {
            Text(bar).foregroundColor(color)
            Text("\(current)/\(max)").foregroundColor(.white)
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
    /// Set by HackView when the terminal session ends (success or
    /// failure). ContentView watches this to apply damage or trigger
    /// the unblockable enemy swing, then clears it back to nil.
    @Published var hackOutcome: HackOutcome? = nil
    /// Bumped by the "Open Hack Terminal" debug command. ContentView
    /// watches this and pops the hack window without needing a
    /// battle, so the minigame can be iterated on standalone.
    @Published var hackTestRequest: Int = 0

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

    /// Number of views currently asking for live camera frames.
    /// Touched only on the main queue.
    private var consumerCount = 0
    /// True once the AVCaptureSession's inputs/outputs have been set
    /// up. Touched only on `sessionQueue`. We keep the configuration
    /// across release/acquire cycles so re-starting is cheap.
    private var configured = false

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

    /// Register one consumer that needs live camera frames. The
    /// underlying AVCaptureSession only runs while at least one
    /// consumer is active. First-ever acquire triggers authorization.
    func acquire() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.consumerCount += 1
            guard self.consumerCount == 1 else { return }
            self.beginCapture()
        }
    }

    /// Pair to `acquire`. Stops the session when the last consumer
    /// releases. Configuration is preserved so the next acquire is
    /// cheap.
    func release() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.consumerCount = max(0, self.consumerCount - 1)
            guard self.consumerCount == 0 else { return }
            self.endCapture()
        }
    }

    private func beginCapture() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted, let self else { return }
                self.startSession()
            }
        default:
            return
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configureSession()
                self.configured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func endCapture() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
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
            // it would appear (manual menu pick, or a mode-switch
            // while open). Auto-open at launch is suppressed at the
            // scene level.
            .onAppear {
                camera.acquire()
                if dieKind == DieKind.d20.rawValue {
                    dismissWindow(id: "orb")
                }
            }
            .onDisappear { camera.release() }
            .onChange(of: dieKind) { newValue in
                if newValue == DieKind.d20.rawValue {
                    dismissWindow(id: "orb")
                }
            }
    }
}

/// Compact die-roller embedded in the camera preview during Adventure
/// mode. Same scene as the standalone window, with smaller result text
/// and a rounded frame. Driven entirely by keyboard (spacebar) in
/// Adventure mode — `shaking` mirrors the spacebar's pressed state.
struct EmbeddedOrbView: View {
    let shaking: Bool
    /// When non-nil, supersedes the user's `dieKind` preference for
    /// this orb. Used to force a d6 during attack rolls while the
    /// player's Adventure-mode default stays d20 for Flee.
    var dieKindOverride: String? = nil
    @EnvironmentObject var camera: CameraController
    @AppStorage(DieKind.storageKey) private var dieKind: String = DieKind.d6.rawValue

    private var activeKind: String { dieKindOverride ?? dieKind }

    var body: some View {
        OrbSceneView(camera: camera, hand: camera.hands.first,
                     keyboardMode: true, keyboardShaking: shaking,
                     dieKindOverride: dieKindOverride)
            .id(activeKind)
            .background(Color(white: 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
    }
}

/// Renders a faceted crystal that the viewer can see being manipulated:
/// rotation tracks hand roll, scale tracks total grip, and five
/// color-coded markers float at the fingertip positions in 3D — closer
/// to the crystal as each finger curls.
struct OrbSceneView: NSViewRepresentable {
    let camera: CameraController
    let hand: HandPose?
    /// When true, the Coordinator ignores hand input and lets the
    /// parent drive the die via `keyboardShaking` (hold-to-shake,
    /// release-to-throw). Used in Adventure mode.
    var keyboardMode: Bool = false
    /// Parent-controlled "is the user holding the shake key?" flag.
    /// Only consulted when keyboardMode is true.
    var keyboardShaking: Bool = false
    /// Per-instance override for which die geometry/face-count to
    /// use. When nil, falls back to `DieKind.current` (the user's
    /// AppStorage preference). Used to render a d6 for Fight rolls
    /// while the Adventure-mode default stays d20 for Flee.
    var dieKindOverride: String? = nil

    private var activeKind: DieKind {
        if let raw = dieKindOverride, let k = DieKind(rawValue: raw) { return k }
        return .current
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.dieKind = activeKind
        return c
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(white: 0.04, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = true

        let (scene, crystal, markers) = Self.buildScene(kind: activeKind)
        view.scene = scene

        context.coordinator.crystalNode = crystal
        context.coordinator.markerNodes = markers
        context.coordinator.camera = camera
        context.coordinator.dieKind = activeKind
        view.delegate = context.coordinator

        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.targetHand = hand
        context.coordinator.keyboardMode = keyboardMode
        context.coordinator.keyboardShaking = keyboardShaking
        context.coordinator.dieKind = activeKind
    }

    /// Returns (scene, dieNode, fingertipMarkers). Used by both the live
    /// SCNView and the offscreen recorder so recordings match the live
    /// view. `kind` controls which die geometry is built; default
    /// keeps the old behavior of reading the user's preference.
    static func buildScene(kind: DieKind = .current) -> (SCNScene, SCNNode, [SCNNode]) {
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

        let die = SCNNode(geometry: makeDieGeometry(kind: kind))
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
        case shaking    // keyboard-driven: continuous spin while spacebar held
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

        /// Pick a random face number from the active die kind that is
        /// NOT the given face. Guarantees the visual roll always lands
        /// on a different face than the one currently up, so even slow
        /// throws produce a clear "the die changed" moment. Instance
        /// method (was static) so each Orb can drive a different die
        /// kind — e.g., d6 for Fight, d20 for Flee.
        func randomFaceExcluding(_ excluded: Int) -> Int {
            let count = dieKind.faceCount
            guard count > 1 else { return 1 }
            var pick = Int.random(in: 1..<count)  // 1...count-1
            if pick >= excluded { pick += 1 }      // skip the excluded slot
            return pick
        }

        /// Die kind this coordinator is currently driving. Pushed in
        /// by `OrbSceneView.makeNSView` / `updateNSView` so face-count
        /// math and orientation lookups always match the rendered
        /// geometry.
        var dieKind: DieKind = .d6

        weak var crystalNode: SCNNode?
        var markerNodes: [SCNNode] = []
        weak var camera: CameraController?

        var targetHand: HandPose?
        // When true, hand input is ignored and the die is driven by
        // `keyboardShaking` (hold/release pattern). Set per-frame
        // from the SwiftUI representable.
        var keyboardMode: Bool = false
        var keyboardShaking: Bool = false
        /// Time accumulated in the current shake. Drives the
        /// hand-like side-to-side oscillation.
        private var shakeElapsed: Float = 0

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

            if keyboardMode {
                runKeyboardFrame(dt: dt)
                publishKeyboardSnapshot()
                return
            }

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
            case .shaking:
                // Unreachable in motion mode (only the keyboard
                // branch transitions into .shaking, and that path
                // returned early above). Listed so the switch is
                // exhaustive.
                break
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
                    rolledFace = randomFaceExcluding(
                        OrbSceneView.nearestFace(to: dieOrientation, kind: dieKind))
                    dieResult = nil
                    dieState = .spinning
                    let firePath = pathA ? "A_growth" : "B_speed"
                    Self.debugLog(String(format: "FIRE path=\(firePath) growth=%.4f peakSpd=%.2f throwSpd=%.2f",
                                         forwardGrowth, peakSpeed, throwSpeed))
                    wasGripped = false
                    peakSpeed = 0
                    camera?.appendGameMessage(Lexicon.rolledDie())
                } else if wasGripped && totalPress < 0.5 {
                    // Released without a qualifying throw — gentle
                    // roll: pick a random face and quickly tumble to
                    // it. Lower starting angular velocity so the spin
                    // visibly differs from a "real" thrown roll, but
                    // still produces a fresh result every grip-release.
                    let face = randomFaceExcluding(
                        OrbSceneView.nearestFace(to: dieOrientation, kind: dieKind))
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
                    camera?.appendGameMessage(Lexicon.rolledDie())
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
                        let target = OrbSceneView.orientationFor(faceNumber: face, kind: dieKind)
                        let approach = (3 - speed) / 3
                        let step = min(1, approach * dt * 6)
                        dieOrientation = simd_slerp(dieOrientation, target, step)
                    }
                } else {
                    if let face = rolledFace {
                        dieOrientation = OrbSceneView.orientationFor(faceNumber: face, kind: dieKind)
                        dieResult = face
                        camera?.appendGameMessage(Lexicon.rolledFace(face))
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
                    case .shaking:  return "shake"
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

        /// Hold-spacebar-to-shake / release-to-throw state machine.
        /// Used in Adventure mode; ignores hand input entirely.
        private func runKeyboardFrame(dt: Float) {
            // Hand-shake oscillation: a person rattling dice in their
            // hand mostly moves them side-to-side at a few Hz, with a
            // smaller vertical bob at double frequency (so the motion
            // traces a figure-8-ish path), plus chaotic tumbling
            // inside the cupped hand. We approximate that with a
            // horizontal sine + vertical sine at 2x + a moderate
            // continuous rotation. The throw on release picks a
            // fresh, faster tumble axis to make the toss feel
            // distinct from the shake.
            let shakeFreqHz: Float = 4.0
            let shakeAmpX: Float = 0.45
            let shakeAmpY: Float = 0.12
            let shakeTumbleSpeed: Float = 14
            let throwTumbleSpeed: Float = 40

            switch dieState {
            case .tracking, .settled:
                if keyboardShaking {
                    // Start a shake. Moderate spin (it's tumbling in a
                    // hand, not free-spinning).
                    shakeElapsed = 0
                    let tumble = SIMD3<Float>(
                        Float.random(in: -1...1),
                        Float.random(in: -1...1),
                        Float.random(in: -0.5...0.5)
                    )
                    let len = simd_length(tumble)
                    let axis = len > 0.001 ? tumble / len : SIMD3<Float>(1, 0, 0)
                    angularVelocity = axis * shakeTumbleSpeed
                    dieResult = nil
                    rolledFace = nil
                    dieState = .shaking
                }
            case .shaking:
                shakeElapsed += dt
                // Position oscillation.
                let omega = 2 * Float.pi * shakeFreqHz
                let xOff = shakeAmpX * sin(omega * shakeElapsed)
                let yOff = shakeAmpY * sin(2 * omega * shakeElapsed)
                crystalNode?.position = SCNVector3(Double(xOff), Double(yOff), 0)
                // Moderate tumble rotation, no decay while held.
                let speed = simd_length(angularVelocity)
                if speed > 0.5 {
                    let axis = angularVelocity / speed
                    let dq = simd_quatf(angle: speed * dt, axis: axis)
                    dieOrientation = simd_mul(dq, dieOrientation)
                }
                if !keyboardShaking {
                    // Release: snap back to center, pre-pick a face,
                    // give a fresh fast tumble, hand off to .spinning
                    // so the existing decay-and-settle logic finishes
                    // the roll.
                    crystalNode?.position = SCNVector3(0, 0, 0)
                    let tumble = SIMD3<Float>(
                        Float.random(in: -1...1),
                        Float.random(in: -1...1),
                        Float.random(in: -0.5...0.5)
                    )
                    let len = simd_length(tumble)
                    let axis = len > 0.001 ? tumble / len : SIMD3<Float>(1, 0, 0)
                    angularVelocity = axis * throwTumbleSpeed
                    let face = randomFaceExcluding(
                        OrbSceneView.nearestFace(to: dieOrientation, kind: dieKind))
                    rolledFace = face
                    dieState = .spinning
                    camera?.appendGameMessage(Lexicon.rolledDie())
                }
            case .spinning:
                let speed = simd_length(angularVelocity)
                if speed > 0.5 {
                    let axis = angularVelocity / speed
                    let dq = simd_quatf(angle: speed * dt, axis: axis)
                    dieOrientation = simd_mul(dq, dieOrientation)
                    angularVelocity *= exp(-2.2 * dt)
                    if let face = rolledFace, speed < 3 {
                        let target = OrbSceneView.orientationFor(faceNumber: face, kind: dieKind)
                        let approach = (3 - speed) / 3
                        let step = min(1, approach * dt * 6)
                        dieOrientation = simd_slerp(dieOrientation, target, step)
                    }
                } else {
                    if let face = rolledFace {
                        dieOrientation = OrbSceneView.orientationFor(faceNumber: face, kind: dieKind)
                        dieResult = face
                        camera?.appendGameMessage(Lexicon.rolledFace(face))
                    }
                    rolledFace = nil
                    angularVelocity = .zero
                    dieState = .settled
                }
            }
        }

        /// Snapshot for keyboard mode — no hand data, just die state.
        /// markers naturally fade out because handPresence is 0.
        private func publishKeyboardSnapshot() {
            let snap = OrbSnapshot(
                roll: 0,
                totalPress: 0,
                fingertipPositions: Array(repeating: SIMD2(0.5, 0.5), count: 5),
                fingertipStrengths: [0, 0, 0, 0, 0],
                handPresence: 0,
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

// MARK: - Hack minigame
//
// The Hack action opens a fake-terminal window that takes the place
// of a die roll. Three planned phases — decrypt, login, inside.
// Phases 1 (decrypt) and 2 (login) are live; phase 3 (PID hunt) is
// still a placeholder that auto-resolves to success after login.
//
// Phase 1 (decrypt) tension comes from a draining "install bar"
// meter: the player has a fixed budget to figure out the rot key
// (hidden somewhere in the fake environment — `ps`, `env`, etc.)
// and type `rot N`. Wrong guesses and misfires shave seconds off
// the meter; empty meter (or four bad keys) ends the session as
// failure.
//
// Phase 2 (login) reuses the same meter — it does not refresh on
// phase transition, so the player feels continuous time pressure
// and has incentive to crack decrypt fast. The decrypted cleartext
// is `user:pass`; the prompt rotates `login:` → `password:` and the
// player retypes each half from memory (or the scrollback). Three
// wrong attempts total → auth lockout → failure. `keepalive` and
// `help` are still accepted; everything else is an auth attempt.
//
// Either phase failing routes to `handleHackOutcome(.failure)` and
// costs the player a free enemy turn.

enum HackOutcome: Equatable {
    /// Decrypt landed. `score` plays the role of the d6 in the
    /// standard damage formula — ContentView applies
    /// `max(1, MAG + score − MDF)`. Scaled by leftover meter so a
    /// fast crack rewards bigger.
    case success(score: Int)
    /// Meter expired, or the player burned their attempts. Caller
    /// hands the enemy a free hit.
    case failure
}

/// Pure helpers for the Caesar puzzle. Kept off the view so unit
/// testing later doesn't need a SwiftUI host.
enum HackPuzzle {
    /// Cleartext credential pool. Lowercase letters + digits + a
    /// punctuation glyph so the rotated form *looks* scrambled but
    /// the symbols are obvious anchors when it snaps back.
    static let credSamples: [String] = [
        "shade:m4!kr0n",
        "ghost:r1!byte",
        "ember:c0re!2x",
        "nyx:hi!ghway7",
        "orin:p4!l0ck"
    ]

    static func makeCreds() -> String {
        credSamples.randomElement() ?? credSamples[0]
    }

    /// Last picked location, persisted across HackView instances so
    /// we can avoid back-to-back repeats. Resets only on app launch
    /// — fine for the test-loop cadence.
    private static var lastKeyLocation: HackKeyLocation? = nil

    /// Pick a key location, never matching the previous one. With 8
    /// spots in the pool that's ~14% per command after the first,
    /// vs the old 33% across 3 spots that made env feel sticky.
    static func makeKeyLocation() -> HackKeyLocation {
        let all = HackKeyLocation.allCases
        let pool = (lastKeyLocation == nil)
            ? all
            : all.filter { $0 != lastKeyLocation }
        let picked = pool.randomElement() ?? all[0]
        lastKeyLocation = picked
        return picked
    }

    /// Caesar rotation; letters only, case-preserving. Digits and
    /// punctuation pass through untouched so the cipher still reads
    /// as a credential and the decrypt visibly "snaps" rather than
    /// just shifting random glyphs.
    static func rot(_ s: String, by n: Int) -> String {
        let shift = ((n % 26) + 26) % 26
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            guard let scalar = ch.unicodeScalars.first else { out.append(ch); continue }
            let v = scalar.value
            if v >= 65 && v <= 90 {
                let r = (Int(v - 65) + shift) % 26
                out.append(Character(UnicodeScalar(UInt32(r) + 65)!))
            } else if v >= 97 && v <= 122 {
                let r = (Int(v - 97) + shift) % 26
                out.append(Character(UnicodeScalar(UInt32(r) + 97)!))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

/// Where the rot key is hidden on this run. Each command in the
/// fake environment is a "look here" surface; the player has to
/// poke around to find which one carries the offset. Each location
/// has its own visual tell so a player who's seen it once can spot
/// it again at a glance.
enum HackKeyLocation: CaseIterable {
    case ps         // a row in `ps` ends with `key=N`
    case env        // an env var `SHIFT=N`
    case version    // `cat /etc/version` reports `(build N)`
    case whoami     // `whoami` prints a uid in the small-N range
    case uptime     // `uptime` reads in hours instead of days
    case motd       // `cat /etc/motd` mentions `grid cycle N`
    case history    // `history` includes `export OFFSET=N`
    case netstat    // `netstat` lists a port `:N` tagged [auth]
}

struct HackView: View {
    @EnvironmentObject var camera: CameraController
    @Environment(\.dismissWindow) private var dismissWindow

    // Puzzle state (sealed in onAppear).
    @State private var rotKey: Int = 0
    @State private var cleartext: String = ""
    @State private var ciphertext: String = ""
    @State private var keyLocation: HackKeyLocation = .ps

    // Terminal state.
    @State private var lines: [TerminalLine] = []
    @State private var input: String = ""
    @State private var phase: HackPhase = .decrypt
    @State private var attempts: Int = 0
    @State private var done: Bool = false   // guard against double-fire on outcome

    // Phase 2 (login). `loginStage` walks `login:` → `password:`;
    // `loginStrikes` counts wrong creds across both prompts. Reset
    // every session in `start()`.
    @State private var loginStage: LoginStage = .username
    @State private var loginStrikes: Int = 0
    enum LoginStage { case username, password }

    // Meter.
    @State private var totalSeconds: Double = 28.0
    @State private var remaining: Double = 28.0
    @State private var lastTick: Date = Date()
    @State private var frozen: Bool = false  // pauses meter during success outro
    /// Wall-clock start of the current session. Score is computed
    /// from elapsed time (not leftover meter) so a `keepalive` refill
    /// keeps the player alive without padding the damage payout.
    @State private var sessionStart: Date = Date()
    /// How many keepalive refills the player has used this session.
    @State private var keepaliveUses: Int = 0

    @FocusState private var inputFocused: Bool

    private static let maxAttempts = 4
    /// Max keepalive refills per session. Each one snaps the meter
    /// back to full — generous on purpose so a stuck player doesn't
    /// just lose to the clock.
    private static let keepaliveMax = 2
    /// Strikes allowed in the login phase before the auth daemon
    /// locks out the session. Three is tight enough to bite without
    /// being punitive for a typo on a clearly-readable cleartext.
    private static let loginMaxStrikes = 3

    /// 10 Hz tick. Cheap, and snappy enough that the meter reads as
    /// real-time rather than stepped.
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    enum HackPhase { case decrypt, login, inside, done }

    struct TerminalLine: Identifiable {
        let id = UUID()
        let text: String
        let style: LineStyle
    }
    enum LineStyle { case command, output, system, error, success }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            terminalPane
            MeterView(remaining: remaining, total: totalSeconds)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            Text(footerHint)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(Color.black)
        .frame(minWidth: 540, minHeight: 420)
        .onAppear(perform: start)
        .onDisappear {
            // Manual close (red dot, Cmd-W) or any path that didn't
            // post an outcome — treat as failure so the battle loop
            // doesn't deadlock on resolvingRoll.
            if !done {
                camera.hackOutcome = .failure
                done = true
            }
        }
        .onReceive(tick) { now in advanceTimer(now: now) }
    }

    // MARK: Layout pieces

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Circle().fill(.yellow).frame(width: 10, height: 10)
            Circle().fill(.green).frame(width: 10, height: 10)
            Spacer()
            Text("root@shade-04  —  secure shell")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green.opacity(0.7))
            Spacer()
            Text("[hack]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black)
        .overlay(Rectangle().frame(height: 1)
                    .foregroundStyle(.green.opacity(0.25)),
                 alignment: .bottom)
    }

    private var terminalPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        terminalText(line).id(line.id)
                    }
                    if phase == .decrypt || phase == .login || phase == .inside {
                        HStack(spacing: 6) {
                            Text(promptText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.green)
                            TextField("", text: $input)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.green)
                                .focused($inputFocused)
                                .onSubmit(submit)
                                .id("input")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("input", anchor: .bottom)
                }
            }
        }
        .background(Color.black)
    }

    private func terminalText(_ line: TerminalLine) -> some View {
        let color: Color
        switch line.style {
        case .command: color = .green
        case .output:  color = .green.opacity(0.85)
        case .system:  color = .cyan
        case .error:   color = .red.opacity(0.85)
        case .success: color = .yellow
        }
        return Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptText: String {
        switch phase {
        case .decrypt: return "$"
        case .login:   return loginStage == .username ? "login:" : "password:"
        case .inside:  return "shade@core:~#"
        case .done:    return ""
        }
    }

    private var footerHint: String {
        switch phase {
        case .decrypt:
            let left = Self.keepaliveMax - keepaliveUses
            return "  ls │ cat │ ps │ env │ whoami │ uptime │ history │ netstat │ rot N │ keepalive[\(left)] │ help"
        case .login:
            let left = Self.keepaliveMax - keepaliveUses
            let triesLeft = Self.loginMaxStrikes - loginStrikes
            return "  type the decrypted credentials  │  keepalive[\(left)]  │  \(triesLeft) tries left"
        case .inside:  return "  ps │ kill <pid> │ rm <path> │ help"
        case .done:    return ""
        }
    }

    // MARK: Session lifecycle

    private func start() {
        // Reset ALL session state. AppKit keeps the HackView instance
        // alive across dismiss/open cycles, so without this the second
        // session inherits the first one's `done = true` (finish()
        // would short-circuit), old terminal lines, a drained meter,
        // and a `.done` phase that hides the input field.
        lines.removeAll()
        input = ""
        phase = .decrypt
        attempts = 0
        loginStage = .username
        loginStrikes = 0
        done = false
        frozen = false
        remaining = totalSeconds
        keepaliveUses = 0
        sessionStart = Date()

        cleartext = HackPuzzle.makeCreds()
        rotKey = Int.random(in: 3...22)
        ciphertext = HackPuzzle.rot(cleartext, by: rotKey)
        keyLocation = HackPuzzle.makeKeyLocation()

        addLine("[ root@shade-04 — secure shell ]", .system)
        addLine("[ session opened. decrypt cred to enter. ]", .system)
        addLine("", .output)
        addLine("$ decrypt ./shade.cred", .command)
        addLine("shade.cred ▸ encrypted", .output)
        addLine(ciphertext, .output)
        addLine("[ key required — locate the offset, then run `rot N` ]", .system)
        addLine("", .output)

        lastTick = Date()
        DispatchQueue.main.async { inputFocused = true }
    }

    private func advanceTimer(now: Date) {
        guard !done, !frozen else { lastTick = now; return }
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        remaining = max(0, remaining - dt)
        if remaining <= 0 { timeout() }
    }

    private func submit() {
        let raw = input
        input = ""
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        addLine("\(promptText) \(cmd)", .command)
        switch phase {
        case .decrypt: handleDecrypt(cmd)
        case .login:   handleLogin(cmd)
        case .inside:  handleInside(cmd)
        case .done:    break
        }
    }

    // MARK: Phase 1 — decrypt

    private func handleDecrypt(_ cmd: String) {
        let parts = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first?.lowercased() else { return }
        let arg = parts.dropFirst().first ?? ""
        switch head {
        case "help":
            addLine("commands:", .output)
            addLine("  ls  cat <file>  ps  env  whoami  uptime  history  netstat", .output)
            addLine("  rot N  keepalive  help  clear", .output)
            addLine("  (keepalive refills the meter, up to \(Self.keepaliveMax) times)", .output)
        case "ls":
            addLine("shade.cred  /etc/version  /etc/motd  /var/log/access.log  /sys/render", .output)
        case "cat":
            renderCat(arg: arg)
        case "ps":
            renderPs()
        case "env":
            renderEnv()
        case "whoami":
            renderWhoami()
        case "uptime":
            renderUptime()
        case "history":
            renderHistory()
        case "netstat":
            renderNetstat()
        case "keepalive":
            runKeepalive()
        case "decrypt":
            addLine("already staged — cleartext locked, key required", .output)
        case "rot":
            if let n = Int(arg), n >= 0, n <= 25 {
                attemptRot(n: n)
            } else {
                addLine("usage: rot <0..25>", .error)
                penalty(0.5)
            }
        case "clear":
            lines.removeAll()
        default:
            addLine("\(head): command not found", .error)
            penalty(1.0)
        }
    }

    private func renderCat(arg: String) {
        switch arg {
        case "shade.cred":
            addLine(ciphertext, .output)
        case "/etc/version":
            // Build number always shown — the cipher signal is that
            // a small build (3..22) means this file holds the key.
            let build = (keyLocation == .version) ? rotKey : Int.random(in: 30...90)
            addLine("shade-os 4.4 (build \(build)) [stable]", .output)
        case "/etc/motd":
            if keyLocation == .motd {
                addLine("[motd] grid cycle \(rotKey) — auth window closing.", .output)
            } else {
                addLine("[motd] welcome to shade-os. report bugs to /dev/null.", .output)
            }
        case "/var/log/access.log":
            addLine("session #\(Int.random(in: 100...999)) ▸ refused", .output)
            addLine("session #\(Int.random(in: 100...999)) ▸ refused", .output)
            addLine("session #\(Int.random(in: 100...999)) ▸ refused", .output)
        case "/sys/render":
            addLine("(binary)", .output)
        case "":
            addLine("usage: cat <file>", .error)
            penalty(0.5)
        default:
            addLine("cat: \(arg): no such file", .error)
            penalty(0.5)
        }
    }

    private func renderPs() {
        addLine("  PID  CMD", .output)
        addLine("  001  init", .output)
        let renderRow = keyLocation == .ps
            ? "  044  /sys/render        key=\(rotKey)"
            : "  044  /sys/render"
        addLine(renderRow, .output)
        addLine("  108  /ai/aggression", .output)
        addLine("  211  /ai/defense", .output)
        addLine("  337  /core/heart", .output)
    }

    private func renderEnv() {
        addLine("USER=shade", .output)
        addLine("HOME=/home/shade", .output)
        addLine("SHELL=/bin/dsh", .output)
        if keyLocation == .env {
            addLine("SHIFT=\(rotKey)", .output)
        }
        addLine("PATH=/usr/bin:/bin", .output)
    }

    /// Real uids are 1000+. When this command holds the key we print
    /// a small uid in the 3..22 range, which reads as "off" and so
    /// signals the offset.
    private func renderWhoami() {
        addLine("shade", .output)
        addLine("groups: shade, grid, render", .output)
        if keyLocation == .whoami {
            addLine("uid=\(rotKey) gid=100", .output)
        } else {
            addLine("uid=1003 gid=100", .output)
        }
    }

    /// A normal uptime reads in days. When this command holds the
    /// key it reads in hours instead — a small N that wants to be
    /// noticed.
    private func renderUptime() {
        if keyLocation == .uptime {
            addLine("up \(rotKey) hours, 1 session, load 0.42", .output)
        } else {
            addLine("up 3 days, 17:42, 1 session, load 0.14", .output)
        }
    }

    /// Recent shell lines. Holds the key when one of the lines is
    /// an explicit `export OFFSET=N`.
    private func renderHistory() {
        var entries = ["ls -la", "ps -ef", "cat /etc/motd", "cd /sys", "ls /var", "ps"]
        if keyLocation == .history {
            entries.insert("export OFFSET=\(rotKey)", at: 2)
        }
        addLine("history:", .output)
        for (i, e) in entries.enumerated() {
            addLine(String(format: "  %3d  %@", i + 1, e), .output)
        }
    }

    /// Standard port listing. When this command holds the key one
    /// of the rows is a port `:N` tagged `[auth]` to mark it as the
    /// offset.
    private func renderNetstat() {
        addLine("proto  local            state", .output)
        addLine("tcp    0.0.0.0:22       LISTEN", .output)
        if keyLocation == .netstat {
            addLine("tcp    0.0.0.0:\(rotKey)        LISTEN  [auth]", .output)
        }
        addLine("tcp    0.0.0.0:80       LISTEN", .output)
        addLine("udp    0.0.0.0:443      LISTEN", .output)
    }

    private func attemptRot(n: Int) {
        if n == rotKey {
            addLine(cleartext, .success)
            addLine("[ key accepted — credential recovered ]", .success)
            frozen = true
            advanceFromDecrypt()
        } else {
            addLine("[ key rejected — text still garbled ]", .error)
            attempts += 1
            penalty(2.0)
            if attempts >= Self.maxAttempts && !done {
                addLine("[ too many bad keys — connection terminated ]", .error)
                finish(.failure)
            }
        }
    }

    /// Phase 1 → 2 bridge. Short freeze so the player reads the
    /// "key accepted" snap, then we resume the meter and rotate
    /// into the login prompts. No meter refresh on transition —
    /// continuous pressure is the whole point of the act break.
    private func advanceFromDecrypt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !done else { return }
            phase = .login
            frozen = false
            addLine("", .output)
            addLine("[ auth daemon online — present credentials ]", .system)
            // Defensive re-focus: the TextField persists across the
            // phase change, but the prompt label swap can race with
            // SwiftUI's focus bookkeeping on rebuild.
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    /// Translate elapsed time into the 1..6 score slot. Counting
    /// from wall-clock start (not leftover meter) means a player who
    /// burned a keepalive can still finish the puzzle but won't max
    /// the score — the refill bought them survival, not damage.
    /// Mirrors the meter→score mapping for clean runs: a sub-second
    /// crack maxes at 6, end-of-budget cracks score 1.
    private func scoreFromTimer() -> Int {
        let elapsed = Date().timeIntervalSince(sessionStart)
        let frac = max(0, min(1, 1 - elapsed / totalSeconds))
        return max(1, min(6, Int((frac * 5.0).rounded()) + 1))
    }

    /// `keepalive`: snap the meter back to full. The connection
    /// metaphor (TCP keepalive packets) is the most terminal-native
    /// way to dress up "I need more time" — and it gives the player
    /// a clear, opt-in save without rebalancing the base timer.
    private func runKeepalive() {
        guard !frozen else { return }
        if keepaliveUses >= Self.keepaliveMax {
            addLine("keepalive: rate-limit exceeded — no refresh slots left", .error)
            return
        }
        keepaliveUses += 1
        let remainingUses = Self.keepaliveMax - keepaliveUses
        remaining = totalSeconds
        addLine("[ keepalive ▸ connection refreshed — \(remainingUses) left ]", .success)
    }

    // MARK: Phase 2 — login

    /// Two-step credential gate. The decrypted cleartext is
    /// `user:pass`; we split once and match each half against the
    /// current prompt. `keepalive` and `help` are still honored so
    /// the player retains the same survive-the-clock affordances
    /// from Phase 1. Anything else is treated as an auth attempt
    /// and burns a strike on mismatch.
    private func handleLogin(_ cmd: String) {
        let lower = cmd.lowercased()
        switch lower {
        case "help":
            addLine("auth daemon: enter the username, then the password.", .output)
            addLine("(\(Self.loginMaxStrikes) bad creds triggers lockout. keepalive still works.)", .output)
            return
        case "keepalive":
            runKeepalive()
            return
        default:
            break
        }
        // Cleartext shape is `user:pass`. Anything else is a bug
        // in the cred pool — fail safe rather than misjudge input.
        let halves = cleartext.split(separator: ":", maxSplits: 1,
                                     omittingEmptySubsequences: false).map(String.init)
        guard halves.count == 2 else {
            finish(.failure)
            return
        }
        let expected = loginStage == .username ? halves[0] : halves[1]
        if cmd == expected {
            if loginStage == .username {
                addLine("[ user recognized — password challenge ]", .system)
                loginStage = .password
            } else {
                addLine("[ access granted ]", .success)
                advanceFromLogin()
            }
            return
        }
        loginStrikes += 1
        let triesLeft = Self.loginMaxStrikes - loginStrikes
        addLine("[ access denied — \(max(0, triesLeft)) tries left ]", .error)
        penalty(1.5)
        if loginStrikes >= Self.loginMaxStrikes && !done {
            addLine("[ auth lockout — connection severed ]", .error)
            finish(.failure)
        }
    }

    /// Phase 2 → success bridge. Phase 3 (PID hunt) is still a
    /// placeholder, so we print the "phase 3 pending" line and
    /// auto-resolve to success. When Phase 3 lands this routes
    /// into the next handler instead.
    private func advanceFromLogin() {
        frozen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            addLine("[ phase 3 — pid hunt : pending ]", .system)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            addLine("EXEC ▸ detonate.payload", .success)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            finish(.success(score: scoreFromTimer()))
        }
    }

    // MARK: Phase 3 — stub

    private func handleInside(_ cmd: String) {}

    // MARK: Helpers

    private func penalty(_ seconds: Double) {
        remaining = max(0, remaining - seconds)
        if remaining <= 0 { timeout() }
    }

    private func timeout() {
        guard !done else { return }
        addLine("", .output)
        addLine("[ session expired — connection dropped ]", .error)
        finish(.failure)
    }

    private func finish(_ outcome: HackOutcome) {
        guard !done else { return }
        done = true
        phase = .done
        // Brief hold so the player reads the last line before the
        // window closes and the battle log picks up the result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            camera.hackOutcome = outcome
        }
    }

    private func addLine(_ text: String, _ style: LineStyle) {
        lines.append(TerminalLine(text: text, style: style))
    }
}

/// Draining "install bar" meter. Mirrors the apt/pip block-bar look
/// — filled glyphs deplete left-to-right rather than fill — and
/// shifts color from green → yellow → red as time runs out so the
/// player feels the pressure without reading the digits.
struct MeterView: View {
    let remaining: Double
    let total: Double

    private static let segments = 28

    private var fraction: Double { max(0, min(1, total > 0 ? remaining / total : 0)) }
    private var filled: Int { Int(fraction * Double(Self.segments)) }
    private var color: Color {
        if fraction > 0.5  { return .green }
        if fraction > 0.25 { return .yellow }
        return .red
    }

    var body: some View {
        let empty = Self.segments - filled
        let bar = String(repeating: "▮", count: max(0, filled))
                + String(repeating: "▯", count: max(0, empty))
        HStack(spacing: 8) {
            Text("connection stable for")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green.opacity(0.55))
            Text(bar)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(color)
            Text(String(format: "%4.1fs", remaining))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}
