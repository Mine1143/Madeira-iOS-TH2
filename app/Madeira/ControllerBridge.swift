// ControllerBridge.swift — MFi / Bluetooth / Xbox / DualSense / DualShock 4
// controller support for Madeira, bridging GameController.framework events
// into Wine's input queue (winios_post_key / winios_pointer).
//
// Mapping (standard XInput-style layout → Windows VK codes):
//   Left stick          → WASD (or mouse-look via right stick config)
//   Right stick         → Mouse movement (camera / aiming)
//   D-pad               → Arrow keys
//   A/B/X/Y             → Space / F / E / R
//   LB/RB               → Q / Left-Shift
//   LT/RT               → Left/Right mouse buttons
//   L3/R3               → Left Ctrl / C
//   Start (+)           → Escape (menu)
//   Back (-)            → Tab
//
// Rumblable: every event is dispatched on a background queue and forwarded
// through the same ring-buffer path as touch input, so the Wine thread
// drains it during pProcessEvents — no extra threads inside Wine.

import Foundation
import GameController

// MARK: - Windows VK codes used by the bridge

enum VK {
    static let LBUTTON: CInt = 0x01
    static let RBUTTON: CInt = 0x02
    static let BACK: CInt = 0x08        // Select/Share/Back
    static let TAB: CInt = 0x09
    static let RETURN: CInt = 0x0D      // Start/Options
    static let SHIFT: CInt = 0x10
    static let CONTROL: CInt = 0x11
    static let ESCAPE: CInt = 0x1B
    static let SPACE: CInt = 0x20
    static let LEFT: CInt = 0x25
    static let UP: CInt = 0x26
    static let RIGHT: CInt = 0x27
    static let DOWN: CInt = 0x28
    static let C: CInt = 0x43
    static let D: CInt = 0x44
    static let E: CInt = 0x45
    static let F: CInt = 0x46
    static let Q: CInt = 0x51
    static let R: CInt = 0x52
    static let S: CInt = 0x53
    static let W: CInt = 0x57
}

// winios_pointer lives in Winios.m and is declared in Winios.h via the
// bridging header, so only the key entry point needs a forward reference.
// (VK codes mirror Winuser.h; MOUSEEVENTF_* mirror Winios.m's definitions.)

// MARK: - Bridge singleton

final class ControllerBridge: ObservableObject {
    static let shared = ControllerBridge()

    @Published var connectedCount: Int = 0
    @Published var lastControllerName: String = ""

    private var started = false
    private let queue = DispatchQueue(label: "madeira.controller", qos: .userInteractive)
    private var mouse: CGPoint = CGPoint(x: 512, y: 384)   // logical 1024x768 space
    private var gamepadHandlers: [Int: [Any]] = [:]        // per-controller observers
    private var dpadStates: [Int: (up: Bool, down: Bool, left: Bool, right: Bool)] = [:]
    private var stickLStates: [Int: (x: Float, y: Float)] = [:]
    private var stickRStates: [Int: (x: Float, y: Float)] = [:]

    // Mouse-look sensitivity (logical px per right-stick unit per tick).
    var rightStickSensitivity: Float = 12.0
    // Left-stick deadzone before WASD edges fire.
    var leftStickDeadzone: Float = 0.35
    // Polling cadence for analog→WASD/mouse translation (Hz).
    private let pollHz: Double = 120
    private var pollTimer: DispatchSourceTimer?

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true

            NotificationCenter.default.addObserver(
                self, selector: #selector(handleConnect(_:)),
                name: .GCControllerDidConnect, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleDisconnect(_:)),
                name: .GCControllerDidDisconnect, object: nil)

            GCController.startWirelessControllerDiscovery { }
            for (i, c) in GCController.controllers().enumerated() {
                attach(c, index: i)
            }
            DispatchQueue.main.async { self.connectedCount = GCController.controllers().count }
        }
    }

    // MARK: Notifications

    @objc private func handleConnect(_ n: Notification) {
        guard let c = n.object as? GCController else { return }
        queue.async { [self] in
            let idx = GCController.controllers().firstIndex(of: c) ?? 0
            attach(c, index: idx)
            DispatchQueue.main.async {
                self.connectedCount = GCController.controllers().count
                self.lastControllerName = c.vendorName ?? "Gamepad"
            }
        }
    }

    @objc private func handleDisconnect(_ n: Notification) {
        guard let c = n.object as? GCController else { return }
        queue.async { [self] in
            detach(c)
            DispatchQueue.main.async {
                self.connectedCount = GCController.controllers().count
            }
        }
    }

    private func attach(_ c: GCController, index: Int) {
        guard gamepadHandlers[index] == nil else { return }
        var obs: [Any] = []

        if let pad = c.extendedGamepad {
            // Buttons — edge-triggered into Wine's key queue
            func watch(_ btn: GCControllerButton?, _ vk: CInt, name: String) {
                guard let btn else { return }
                obs.append(btn.valueChangedHandler = { [weak self] b, pressed, _ in
                    self?.postKey(vk, pressed)
                    if pressed && (name == "A") {
                        // A doubles as Enter on iOS MFi pads that report
                        // no Options button — harmless for games.
                    }
                })
            }
            watch(pad.buttonA, VK.SPACE, name: "A")
            watch(pad.buttonB, VK.F, name: "B")
            watch(pad.buttonX, VK.E, name: "X")
            watch(pad.buttonY, VK.R, name: "Y")
            watch(pad.leftShoulder, VK.Q, name: "LB")
            watch(pad.rightShoulder, VK.SHIFT, name: "RB")
            watch(pad.leftTrigger, VK.LBUTTON, name: "LT")
            watch(pad.rightTrigger, VK.RBUTTON, name: "RT")
            watch(pad.leftThumbstickButton, VK.CONTROL, name: "L3")
            watch(pad.rightThumbstickButton, VK.C, name: "R3")

            // Options/Menu = Start (Escape on Windows menus)
            watch(pad.buttonMenu, VK.ESCAPE, name: "Menu")
            // DualSense/series pads: Share = Tab
            watch(pad.buttonOptions, VK.BACK, name: "Options")

            // D-pad: directional keys, edge-triggered with held-state
            // tracking via the poll timer instead of raw handlers (d-pad
            // reports pressure not edges on some pads).
            dpadStates[index] = (false, false, false, false)
            stickLStates[index] = (0, 0)
            stickRStates[index] = (0, 0)
        }
        gamepadHandlers[index] = obs
        startPolling()
    }

    private func detach(_ c: GCController) {
        // Handlers die with the controller object; just clear state
        if let idx = GCController.controllers().firstIndex(of: c) {
            gamepadHandlers.removeValue(forKey: idx)
            dpadStates.removeValue(forKey: idx)
            stickLStates.removeValue(forKey: idx)
            stickRStates.removeValue(forKey: idx)
        }
    }

    // MARK: Poll timer (analog sticks, d-pad, mouse-look)

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / pollHz)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        pollTimer = t
    }

    private func poll() {
        for (idx, c) in GCController.controllers().enumerated() {
            guard let pad = c.extendedGamepad else { continue }
            guard gamepadHandlers[idx] != nil else { attach(c, index: idx); continue }

            // --- D-pad → arrows (held-state edge detection)
            var dp = dpadStates[idx] ?? (false, false, false, false)
            let dUp = pad.dpad.up.isPressed, dDown = pad.dpad.down.isPressed
            let dLeft = pad.dpad.left.isPressed, dRight = pad.dpad.right.isPressed
            if dUp != dp.up { postKey(VK.UP, dUp) }
            if dDown != dp.down { postKey(VK.DOWN, dDown) }
            if dLeft != dp.left { postKey(VK.LEFT, dLeft) }
            if dRight != dp.right { postKey(VK.RIGHT, dRight) }
            dpadStates[idx] = (dUp, dDown, dLeft, dRight)

            // --- Left stick → WASD (8-direction, deadzoned)
            var l = stickLStates[idx] ?? (0, 0)
            let lx = pad.leftThumbstick.xAxis.value
            let ly = pad.leftThumbstick.yAxis.value
            let mag = sqrtf(lx * lx + ly * ly)
            let active = mag > leftStickDeadzone
            let wx: Float = active ? (abs(lx) > 0.38 ? (lx < 0 ? -1 : 1) : 0) : 0
            let wy: Float = active ? (abs(ly) > 0.38 ? (ly < 0 ? -1 : 1) : 0) : 0
            // W/S follow Y (W = up = +Y); A/D follow X (D = right = +X)
            let wantW = wy > 0, wantS = wy < 0
            let wantA = wx < 0, wantD = wx > 0
            if wantW != (l.y > 0) { postKey(VK.W, wantW) }
            if wantS != (l.y < 0) { postKey(VK.S, wantS) }
            if wantA != (l.x < 0) { postKey(VK.A, wantA) }
            if wantD != (l.x > 0) { postKey(VK.D, wantD) }
            stickLStates[idx] = (wx, wy)

            // --- Right stick → mouse-look (absolute-cursor move)
            var r = stickRStates[idx] ?? (0, 0)
            let rx = pad.rightThumbstick.xAxis.value
            let ry = pad.rightThumbstick.yAxis.value
            if abs(rx) > 0.12 || abs(ry) > 0.12 {
                mouse.x += CGFloat(rx) * CGFloat(rightStickSensitivity)
                mouse.y -= CGFloat(ry) * CGFloat(rightStickSensitivity)
                mouse.x = min(max(mouse.x, 0), 1023)
                mouse.y = min(max(mouse.y, 0), 767)
                winios_pointer(Int32(mouse.x), Int32(mouse.y),
                               0x8000 /*MOUSEEVENTF_ABSOLUTE*/ | 0x0001 /*MOVE*/, 0)
            }
            stickRStates[idx] = (rx, ry)
        }
    }

    // MARK: Forwarding into Wine

    private func postKey(_ vk: CInt, _ down: Bool) {
        winios_post_key(Int(vk), down ? 1 : 0)
    }
}
