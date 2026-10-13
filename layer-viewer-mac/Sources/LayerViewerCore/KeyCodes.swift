// HID Usage（キーボードが送るキーの番号）と macOS の仮想キーコード（CGEvent の keyCode）の対応。
// 記録で、キーボードの報告と macOS が作ったキーリピートを同じキーとして突き合わせるのに使う。
// 値は Carbon の kVK_* 定数（HIToolbox/Events.h）。
import Foundation

public enum KeyCodes {
    private static let pairs: [(usage: Int, keyCode: Int)] = [
        // a〜z
        (0x04, 0), (0x05, 11), (0x06, 8), (0x07, 2), (0x08, 14), (0x09, 3), (0x0A, 5), (0x0B, 4),
        (0x0C, 34), (0x0D, 38), (0x0E, 40), (0x0F, 37), (0x10, 46), (0x11, 45), (0x12, 31), (0x13, 35),
        (0x14, 12), (0x15, 15), (0x16, 1), (0x17, 17), (0x18, 32), (0x19, 9), (0x1A, 13), (0x1B, 7),
        (0x1C, 16), (0x1D, 6),
        // 1〜9, 0
        (0x1E, 18), (0x1F, 19), (0x20, 20), (0x21, 21), (0x22, 23), (0x23, 22), (0x24, 26), (0x25, 28),
        (0x26, 25), (0x27, 29),
        // Enter, Esc, Backspace, Tab, Space, - = [ ] \ ; ' ` , . /
        (0x28, 36), (0x29, 53), (0x2A, 51), (0x2B, 48), (0x2C, 49), (0x2D, 27), (0x2E, 24), (0x2F, 33),
        (0x30, 30), (0x31, 42), (0x33, 41), (0x34, 39), (0x35, 50), (0x36, 43), (0x37, 47), (0x38, 44),
        (0x39, 57),  // Caps Lock
        // F1〜F12
        (0x3A, 122), (0x3B, 120), (0x3C, 99), (0x3D, 118), (0x3E, 96), (0x3F, 97), (0x40, 98), (0x41, 100),
        (0x42, 101), (0x43, 109), (0x44, 103), (0x45, 111),
        // Insert(Help), Home, PgUp, Delete, End, PgDn, →, ←, ↓, ↑
        (0x49, 114), (0x4A, 115), (0x4B, 116), (0x4C, 117), (0x4D, 119), (0x4E, 121), (0x4F, 124), (0x50, 123),
        (0x51, 125), (0x52, 126),
        // F13〜F20
        (0x68, 105), (0x69, 107), (0x6A, 113), (0x6B, 106), (0x6C, 64), (0x6D, 79), (0x6E, 80), (0x6F, 90),
        // JIS: ろ（International1）, ¥（International3）, かな（LANG1）, 英数（LANG2）
        (0x87, 94), (0x89, 93), (0x90, 104), (0x91, 102),
        // 修飾キー: 左 Ctrl, Shift, Alt, GUI, 右 Ctrl, Shift, Alt, GUI
        (0xE0, 59), (0xE1, 56), (0xE2, 58), (0xE3, 55), (0xE4, 62), (0xE5, 60), (0xE6, 61), (0xE7, 54),
    ]

    private static let byUsage = Dictionary(pairs.map { ($0.usage, $0.keyCode) }, uniquingKeysWith: { a, _ in a })
    private static let byKeyCode = Dictionary(pairs.map { ($0.keyCode, $0.usage) }, uniquingKeysWith: { a, _ in a })

    public static func keyCode(forUsage usage: Int) -> Int? { byUsage[usage] }
    public static func usage(forKeyCode keyCode: Int) -> Int? { byKeyCode[keyCode] }
    public static func isModifier(usage: Int) -> Bool { (0xE0...0xE7).contains(usage) }

    /// ログ用の短い名前（文字キーは US 配列の刻印）
    public static func name(usage: Int) -> String {
        if isModifier(usage: usage) { return ["LCtrl", "LShift", "LAlt", "LGUI", "RCtrl", "RShift", "RAlt", "RGUI"][usage - 0xE0] }
        if let c = Labels.char(usage, shifted: false, host: .us), c != "Space" { return c }
        if (0x3A...0x45).contains(usage) { return "F\(usage - 0x3A + 1)" }
        if (0x68...0x73).contains(usage) { return "F\(usage - 0x68 + 13)" }
        let named: [Int: String] = [0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
                                    0x4C: "Delete", 0x4F: "Right", 0x50: "Left", 0x51: "Down", 0x52: "Up",
                                    0x90: "かな", 0x91: "英数"]
        return named[usage] ?? String(format: "usage 0x%02X", usage)
    }
}

/// 観測の時刻をシステムの稼働時間（秒。`ProcessInfo.systemUptime` と同じ基準）にそろえる
public enum Clock {
    private static let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(tb.denom))
    }()

    /// mach_absolute_time の刻み（IOHID の時刻）を秒に
    public static func seconds(machTicks: UInt64) -> Double {
        Double(machTicks) * timebase.numer / timebase.denom / 1e9
    }

    /// 単位がはっきりしない時刻（CGEvent の timestamp はナノ秒とされるが、環境により mach の刻みのことがある）を、
    /// 現在時刻 now に近い方の解釈で秒にする。どちらも合わなければ now を使う
    public static func normalize(_ raw: UInt64, now: Double) -> Double {
        for s in [Double(raw) / 1e9, seconds(machTicks: raw)] where s <= now + 0.5 && now - s < 60 {
            return s
        }
        return now
    }
}
