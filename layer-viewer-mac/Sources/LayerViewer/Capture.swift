// 記録のための観測（入力監視の許可が必要）
//   - SofleKeyboardMonitor: Sofle のキーボード用 HID インターフェースから、キーの押下・解放を読む（横取りはしない）
//   - KeyEventTap: macOS のキーイベント（キーリピートを含む）を読むだけのイベントタップ
// 記録するのはキーの番号と時刻だけで、入力された文字列は組み立てない。
import AppKit
import IOKit.hid
import LayerViewerCore

enum InputMonitoring {
    static var granted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    /// 初回はシステムの確認ダイアログが出る。許可済みなら true
    @discardableResult static func request() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}

final class SofleKeyboardMonitor {
    static let vendorId = 0x1D50, productId = 0x615E

    var onKey: ((_ usage: Int, _ down: Bool) -> Void)?
    private var manager: IOHIDManager?

    /// 開けたら true（入力監視の許可が無いと開けない）
    func start() -> Bool {
        guard manager == nil else { return true }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: Self.vendorId,
            kIOHIDProductIDKey: Self.productId,
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }
            let usage = Int(IOHIDElementGetUsage(element))
            guard (0x04...0xE7).contains(usage) else { return }  // 0xFFFFFFFF 等の「キー無し」を除く
            Unmanaged<SofleKeyboardMonitor>.fromOpaque(ctx!).takeUnretainedValue()
                .onKey?(usage, IOHIDValueGetIntegerValue(value) != 0)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = m
        return true
    }

    func stop() {
        guard let m = manager else { return }
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = nil
    }
}

final class KeyEventTap {
    var onKey: ((_ keyCode: Int, _ down: Bool, _ autorepeat: Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// 作れたら true（入力監視の許可が無いと作れない）
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<KeyEventTap>.fromOpaque(ctx!).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }  // 止められたら戻す
            case .keyDown, .keyUp:
                me.onKey?(Int(event.getIntegerValueField(.keyboardEventKeycode)), type == .keyDown,
                          event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            default: break
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: ctx) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }
}

/// 記録ファイルの書き出し（~/Library/Logs/LayerViewer/）
///   events.log         … 異常と印を1行ずつ追記
///   incident-*.log     … 異常リピート（キーボード内部で押下中を除く）と印のときに、直前の観測を書き出す
enum RecordStore {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LayerViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func append(_ line: String) {
        let url = folder.appendingPathComponent("events.log")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// 直前の観測を書き出し、ファイル名を返す
    static func writeIncident(_ finding: Finding, ring: [TimedEvent], at t: Double, date: Date, version: String) -> String {
        let stamp = RecordFormat.timestamp(date).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "-")
        let name = "incident-\(stamp).log"
        var lines = ["Layer Viewer v\(version)  \(RecordFormat.timestamp(date))",
                     RecordFormat.describe(finding),
                     "", "時刻は異常を検出した瞬間からの相対秒（負は前）:"]
        lines += ring.map { RecordFormat.describe($0, relativeTo: t) }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent(name))
        return name
    }
}
