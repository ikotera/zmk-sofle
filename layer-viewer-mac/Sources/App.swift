// Layer Viewer（macOS ネイティブ版）
// アクティブなレイヤーと押下中のキーを、常に最前面の小窓に表示する。
import AppKit
import IOKit.hid
import ServiceManagement

// MARK: - 設定

enum Settings {
    static let d = UserDefaults.standard
    static var host: HostLayout {
        get { HostLayout(rawValue: d.string(forKey: "host") ?? "") ?? .us }
        set { d.set(newValue.rawValue, forKey: "host") }
    }
    static var showShift: Bool {
        get { d.object(forKey: "showShift") as? Bool ?? true }
        set { d.set(newValue, forKey: "showShift") }
    }
    static var unit: Double {
        get { d.object(forKey: "unit") as? Double ?? 40 }
        set { d.set(newValue, forKey: "unit") }
    }
    static var opacity: Double {
        get { d.object(forKey: "opacity") as? Double ?? 0.92 }
        set { d.set(newValue, forKey: "opacity") }
    }
    static var clickThrough: Bool {
        get { d.bool(forKey: "clickThrough") }
        set { d.set(newValue, forKey: "clickThrough") }
    }
}

// MARK: - Raw HID（ファームウェアの src/layer_report.c からの通知）

final class HIDLink {
    var onReport: ((_ layerMask: UInt32, _ pressed: Set<Int>) -> Void)?
    var onConnection: ((_ name: String?) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices: [IOHIDDevice] = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 0xFF60,
            kIOHIDDeviceUsageKey: 0x61,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ device: IOHIDDevice) {
        devices.append(device)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { ctx, _, _, _, _, report, length in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue()
                .handle(UnsafeBufferPointer(start: report, count: length))
        }, ctx)
        onConnection?(IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Keyboard")
        // 接続直後に現在の状態を問い合わせる
        var req = [UInt8](repeating: 0, count: 32)
        req[0] = 0x4C
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &req, req.count)
    }

    private func detach(_ device: IOHIDDevice) {
        devices.removeAll { $0 == device }
        if devices.isEmpty { onConnection?(nil) }
    }

    private func handle(_ r: UnsafeBufferPointer<UInt8>) {
        guard r.count >= 8, r[0] == 0x4C else { return }
        let mask = UInt32(r[4]) | UInt32(r[5]) << 8 | UInt32(r[6]) << 16 | UInt32(r[7]) << 24
        var pressed = Set<Int>()
        if r[1] >= 2 {
            for i in 8..<r.count where r[i] != 0 {
                for b in 0..<8 where r[i] & (1 << b) != 0 { pressed.insert((i - 8) * 8 + b) }
            }
        }
        onReport?(mask | 1, pressed)
    }
}

// MARK: - 描画

final class KeyboardView: NSView {
    var km: KeymapData?
    var layerMask: UInt32 = 1
    var pressed = Set<Int>()
    var connected: String?
    var message: String?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
    private let cBg = rgb(0x14171c), cKey = rgb(0x222730), cEdge = rgb(0x2b313b)
    private let cText = rgb(0xe8eaee), cMuted = rgb(0x8a919d), cDim = rgb(0x5b6270)
    private let cAccent = rgb(0x7b7cf6), cLayer = rgb(0x4fb3a9), cSys = rgb(0xd79b5a), cOk = rgb(0x57c78a)

    static let header: CGFloat = 24, margin: CGFloat = 8

    /// キー配置全体の範囲（キー単位）。回転したキーは四隅で計算する
    static func bounds(_ keys: [KeyAttr]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for k in keys {
            let x = CGFloat(k.x) / 100, y = CGFloat(k.y) / 100, w = CGFloat(k.width) / 100, h = CGFloat(k.height) / 100
            let rad = CGFloat(k.r) / 100 * .pi / 180, rx = CGFloat(k.rx) / 100, ry = CGFloat(k.ry) / 100
            for (px, py) in [(x, y), (x + w, y), (x, y + h), (x + w, y + h)] {
                let dx = px - rx, dy = py - ry
                let qx = rx + dx * cos(rad) - dy * sin(rad), qy = ry + dx * sin(rad) + dy * cos(rad)
                minX = min(minX, qx); minY = min(minY, qy); maxX = max(maxX, qx); maxY = max(maxY, qy)
            }
        }
        return keys.isEmpty ? CGRect(x: 0, y: 0, width: 14, height: 5) : CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func activeIndices(_ km: KeymapData) -> [Int] {
        km.layers.indices.filter { $0 == 0 || (km.layers[$0].id < 32 && layerMask >> UInt32(km.layers[$0].id) & 1 == 1) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        cBg.withAlphaComponent(0.96).setFill()
        bg.fill()

        guard let km, !km.layers.isEmpty else {
            text(message ?? "キーマップ未取得：左手を USB 接続し、メニューバーの ⌨ →「キーマップ再取得」",
                 at: CGPoint(x: bounds.midX, y: bounds.midY), size: 12, color: cMuted)
            return
        }
        let active = activeIndices(km)
        let top = active.last ?? 0
        drawHeader(km, active: active, top: top)

        let U = CGFloat(Settings.unit), host = Settings.host, showShift = Settings.showShift
        let b = Self.bounds(km.keys)
        let ox = Self.margin - b.minX * U, oy = Self.header + Self.margin - b.minY * U

        for (pos, k) in km.keys.enumerated() {
            // 透過キーは下のアクティブなレイヤーへ落ちる（ZMK と同じ解決順）
            var binding: Binding?, from = top
            for idx in active.reversed() {
                guard pos < km.layers[idx].bindings.count else { continue }
                let bd = km.layers[idx].bindings[pos]
                if km.behaviors[String(bd.behaviorId)] == "Transparent" && idx != 0 { continue }
                binding = bd; from = idx; break
            }
            let lab = binding.map { Labels.label($0, km: km, host: host) } ?? KeyLabel(main: "", kind: .none)
            let isPressed = pressed.contains(pos)

            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: ox + CGFloat(k.rx) / 100 * U, yBy: oy + CGFloat(k.ry) / 100 * U)
            t.rotate(byDegrees: CGFloat(k.r) / 100)
            t.translateX(by: -CGFloat(k.rx) / 100 * U, yBy: -CGFloat(k.ry) / 100 * U)
            t.concat()

            let x = CGFloat(k.x) / 100 * U, y = CGFloat(k.y) / 100 * U
            let w = CGFloat(k.width) / 100 * U, h = CGFloat(k.height) / 100 * U
            let rect = CGRect(x: x + 2, y: y + 2, width: w - 4, height: h - 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: U * 0.12, yRadius: U * 0.12)
            if isPressed { cAccent.setFill(); path.fill() }
            else if lab.kind != .none { cKey.setFill(); path.fill() }
            (isPressed ? cAccent : cEdge).setStroke()
            path.lineWidth = 1
            path.stroke()

            var color: NSColor
            switch lab.kind {
            case .layer: color = cLayer
            case .sys: color = cSys
            case .trans: color = cDim
            default: color = cText
            }
            if from != top && lab.kind != .none { color = cDim }
            if isPressed { color = .white }

            let lines = lab.main.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let longest = lines.map { $0.count }.max() ?? 0
            let base: CGFloat = lines.count > 1 ? 13 : longest <= 1 ? 26 : longest <= 2 ? 20 : longest <= 4 ? 15 : longest <= 6 ? 12 : 10
            let fs = base * U / 60, lh = fs * 1.15
            let cx = x + w / 2, cy = y + h / 2 - (lab.hold != nil ? U * 0.1 : 0)
            for (i, s) in lines.enumerated() {
                text(s, at: CGPoint(x: cx, y: cy + (CGFloat(i) - CGFloat(lines.count - 1) / 2) * lh), size: fs, color: color)
            }
            if showShift, let s = lab.shift {
                text(s, at: CGPoint(x: x + w - U * 0.2, y: y + U * 0.22), size: 11 * U / 60, color: isPressed ? .white : cMuted)
            }
            if let hold = lab.hold {
                text(hold, at: CGPoint(x: cx, y: y + h - U * 0.2), size: 10 * U / 60, color: isPressed ? .white : cLayer)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawHeader(_ km: KeymapData, active: [Int], top: Int) {
        var x = Self.margin + 4
        let y = Self.header / 2 + 4
        for (i, l) in km.layers.enumerated() {
            let isTop = i == top
            let font = NSFont.systemFont(ofSize: 11, weight: isTop ? .bold : .regular)
            let size = (l.name as NSString).size(withAttributes: [.font: font])
            let chip = CGRect(x: x, y: y - 8, width: size.width + 12, height: 16)
            if isTop {
                cAccent.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8).fill()
            } else if active.contains(i) {
                cAccent.setStroke()
                NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            }
            text(l.name, at: CGPoint(x: chip.midX, y: y), size: 11, color: isTop ? .white : cMuted, weight: isTop ? .bold : .regular)
            x += chip.width + 4
        }
        // 右上：レイヤー通知の接続状態
        let dot = CGRect(x: bounds.maxX - Self.margin - 12, y: y - 4, width: 8, height: 8)
        (connected != nil ? cOk : cDim).setFill()
        NSBezierPath(ovalIn: dot).fill()
        if let message {
            let font = NSFont.systemFont(ofSize: 10)
            let w = (message as NSString).size(withAttributes: [.font: font]).width
            text(message, at: CGPoint(x: dot.minX - 6 - w / 2, y: y), size: 10, color: cMuted)
        }
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: attrs)
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let view = KeyboardView()
    private let hid = HIDLink()
    private var statusItem: NSStatusItem!
    private var fetching = false

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = view
        applyWindowSettings()

        view.km = KeymapData.loadCache()
        resize()
        if let s = UserDefaults.standard.string(forKey: "origin") {
            panel.setFrameOrigin(NSPointFromString(s))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "origin")
        }

        hid.onReport = { [weak self] mask, pressed in
            guard let self else { return }
            self.view.layerMask = mask
            self.view.pressed = pressed
            self.view.needsDisplay = true
        }
        hid.onConnection = { [weak self] name in
            guard let self else { return }
            self.view.connected = name
            if name == nil { self.view.layerMask = 1; self.view.pressed = [] }
            self.view.needsDisplay = true
        }
        hid.start()

        setupMenu()
        if view.km == nil { fetchKeymap() }
    }

    private func applyWindowSettings() {
        panel.alphaValue = Settings.opacity
        panel.ignoresMouseEvents = Settings.clickThrough
    }

    private func resize() {
        let U = CGFloat(Settings.unit)
        let b = KeyboardView.bounds(view.km?.keys ?? [])
        let size = CGSize(width: b.width * U + KeyboardView.margin * 2,
                          height: b.height * U + KeyboardView.margin * 2 + KeyboardView.header)
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if top > 0 { panel.setFrameTopLeftPoint(CGPoint(x: panel.frame.minX, y: top)) }
        view.needsDisplay = true
    }

    private func fetchKeymap() {
        guard !fetching else { return }
        fetching = true
        view.message = "キーマップ取得中…"
        view.needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try StudioClient.fetchKeymap() }
            DispatchQueue.main.async {
                self.fetching = false
                switch result {
                case .success(let km):
                    km.saveCache()
                    self.view.km = km
                    self.view.message = nil
                    self.resize()
                case .failure(let e):
                    self.view.message = e.localizedDescription
                    self.view.needsDisplay = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        if self.view.message == e.localizedDescription { self.view.message = nil; self.view.needsDisplay = true }
                    }
                }
            }
        }
    }

    // MARK: メニューバー

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let m = NSMenu()
        func item(_ title: String, _ sel: Selector, on: Bool = false, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off; i.tag = tag
            m.addItem(i)
        }
        item(panel.isVisible ? "表示を隠す" : "表示する", #selector(toggleVisible))
        item("キーマップ再取得（USB）", #selector(refetch))
        m.addItem(.separator())
        item("ホスト配列: US", #selector(setHost), on: Settings.host == .us, tag: 0)
        item("ホスト配列: JIS", #selector(setHost), on: Settings.host == .jis, tag: 1)
        item("Shift 時の文字も表示", #selector(toggleShift), on: Settings.showShift)
        m.addItem(.separator())
        for (i, (name, u)) in [("小", 30.0), ("中", 40.0), ("大", 52.0)].enumerated() {
            item("サイズ: \(name)", #selector(setSize), on: Settings.unit == u, tag: i)
        }
        for (i, o) in [1.0, 0.92, 0.75, 0.55].enumerated() {
            item("不透明度: \(Int(o * 100))%", #selector(setOpacity), on: Settings.opacity == o, tag: i)
        }
        item("クリックを透過（ドラッグ移動不可）", #selector(toggleClickThrough), on: Settings.clickThrough)
        m.addItem(.separator())
        item("ログイン時に起動", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        m.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = m
    }

    @objc private func toggleVisible() {
        panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
        rebuildMenu()
    }
    @objc private func refetch() { fetchKeymap() }
    @objc private func setHost(_ s: NSMenuItem) { Settings.host = s.tag == 1 ? .jis : .us; changed() }
    @objc private func toggleShift() { Settings.showShift.toggle(); changed() }
    @objc private func setSize(_ s: NSMenuItem) { Settings.unit = [30.0, 40.0, 52.0][s.tag]; resize(); changed() }
    @objc private func setOpacity(_ s: NSMenuItem) { Settings.opacity = [1.0, 0.92, 0.75, 0.55][s.tag]; applyWindowSettings(); changed() }
    @objc private func toggleClickThrough() { Settings.clickThrough.toggle(); applyWindowSettings(); changed() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            view.message = "ログイン項目の設定に失敗: \(error.localizedDescription)"
        }
        changed()
    }
    private func changed() { view.needsDisplay = true; rebuildMenu() }
}
