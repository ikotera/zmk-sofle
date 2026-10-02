// キーの割り当て（behavior + パラメータ）を、画面に出すラベルへ変換する。
// 修飾付きのキーは「Shift+2」ではなく、実際に入力される文字（例: @）にする。
import Foundation

enum HostLayout: String { case us, jis }

enum LabelKind { case char, mod, layer, sys, trans, none }

struct KeyLabel {
    var main: String
    var shift: String? = nil  // Shift を押したときに出る文字（補助表示）
    var hold: String? = nil   // ホールド時の動作（Layer-Tap / Mod-Tap）
    var kind: LabelKind = .char
}

enum Labels {
    // [通常, Shift] の組。ホスト OS の配列設定によって変わる部分だけ US / JIS で分ける。
    private static let common: [Int: (String, String)] = {
        var t: [Int: (String, String)] = [0x2c: ("Space", "Space")]
        for i in 0..<26 {
            let c = String(UnicodeScalar(UInt8(97 + i)))
            t[0x04 + i] = (c, c.uppercased())
        }
        return t
    }()
    private static let us: [Int: (String, String)] = [
        0x1e: ("1", "!"), 0x1f: ("2", "@"), 0x20: ("3", "#"), 0x21: ("4", "$"), 0x22: ("5", "%"),
        0x23: ("6", "^"), 0x24: ("7", "&"), 0x25: ("8", "*"), 0x26: ("9", "("), 0x27: ("0", ")"),
        0x2d: ("-", "_"), 0x2e: ("=", "+"), 0x2f: ("[", "{"), 0x30: ("]", "}"), 0x31: ("\\", "|"),
        0x32: ("#", "~"), 0x33: (";", ":"), 0x34: ("'", "\""), 0x35: ("`", "~"), 0x36: (",", "<"),
        0x37: (".", ">"), 0x38: ("/", "?"), 0x64: ("\\", "|"),
    ]
    private static let jis: [Int: (String, String)] = [
        0x1e: ("1", "!"), 0x1f: ("2", "\""), 0x20: ("3", "#"), 0x21: ("4", "$"), 0x22: ("5", "%"),
        0x23: ("6", "&"), 0x24: ("7", "'"), 0x25: ("8", "("), 0x26: ("9", ")"), 0x27: ("0", ""),
        0x2d: ("-", "="), 0x2e: ("^", "~"), 0x2f: ("@", "`"), 0x30: ("[", "{"), 0x31: ("]", "}"),
        0x32: ("]", "}"), 0x33: (";", "+"), 0x34: (":", "*"), 0x35: ("半/全", "半/全"), 0x36: (",", "<"),
        0x37: (".", ">"), 0x38: ("/", "?"), 0x87: ("\\", "_"), 0x89: ("¥", "|"),
    ]
    private static let keyNames: [Int: String] = {
        var t: [Int: String] = [
            0x28: "⏎", 0x29: "Esc", 0x2a: "⌫", 0x2b: "Tab", 0x39: "Caps",
            0x46: "PrtSc", 0x47: "ScrLk", 0x48: "Pause", 0x49: "Ins", 0x4a: "Home", 0x4b: "PgUp",
            0x4c: "Del", 0x4d: "End", 0x4e: "PgDn", 0x4f: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
            0x53: "NumLk", 0x54: "/", 0x55: "*", 0x56: "-", 0x57: "+", 0x58: "⏎", 0x63: ".", 0x62: "0",
            0x65: "Menu", 0x87: "_", 0x88: "かな", 0x89: "¥", 0x8a: "変換", 0x8b: "無変換",
            0x90: "かな", 0x91: "英数", 0x7f: "🔇", 0x80: "🔊", 0x81: "🔉",
        ]
        for i in 0..<12 { t[0x3a + i] = "F\(i + 1)"; t[0x68 + i] = "F\(i + 13)" }
        for i in 0..<9 { t[0x59 + i] = "\(i + 1)" }
        return t
    }()
    private static let consumer: [Int: String] = [
        0xe2: "🔇", 0xe9: "🔊", 0xea: "🔉", 0xcd: "⏯", 0xb5: "⏭", 0xb6: "⏮", 0xb7: "⏹",
        0x6f: "🔆", 0x70: "🔅", 0xb8: "⏏",
    ]
    private static let modKeys: [Int: String] = [
        0xe0: "⌃ Ctrl", 0xe1: "⇧ Shift", 0xe2: "⌥ Opt", 0xe3: "⌘ Cmd",
        0xe4: "⌃ Ctrl", 0xe5: "⇧ Shift", 0xe6: "⌥ Opt", 0xe7: "⌘ Cmd",
    ]
    private static let modBits: [(UInt32, String)] = [(0x11, "⌃"), (0x44, "⌥"), (0x22, "⇧"), (0x88, "⌘")]

    static func char(_ id: Int, shifted: Bool, host: HostLayout) -> String? {
        guard let pair = common[id] ?? (host == .jis ? jis : us)[id] else { return nil }
        return shifted ? pair.1 : pair.0
    }

    static func modPrefix(_ mods: UInt32) -> String {
        modBits.filter { mods & $0.0 != 0 }.map { $0.1 }.joined()
    }

    /// ZMK のキーコード（上位 8bit = 修飾, 次の 8bit = Usage Page, 下位 16bit = Usage ID）
    static func key(_ code: UInt32, host: HostLayout) -> KeyLabel {
        let mods = (code >> 24) & 0xff, page = (code >> 16) & 0xff, id = Int(code & 0xffff)
        if page == 0x0c { return KeyLabel(main: consumer[id] ?? String(format: "C:%x", id)) }
        guard page == 0x07 else { return KeyLabel(main: String(format: "?%x", code)) }
        if let m = modKeys[id] { return KeyLabel(main: m, kind: .mod) }
        let shift = mods & 0x22 != 0, other = mods & ~0x22
        if let ch = char(id, shifted: shift, host: host), !ch.isEmpty {
            if other != 0 { return KeyLabel(main: modPrefix(other) + (shift ? ch : ch.uppercased())) }
            var label = KeyLabel(main: ch)
            if !shift, let alt = char(id, shifted: true, host: host), alt != ch, alt != ch.uppercased() {
                label.shift = alt
            }
            return label
        }
        return KeyLabel(main: modPrefix(mods) + (keyNames[id] ?? String(format: "0x%x", id)))
    }

    private static let bt = ["BT Clr", "BT ▶", "BT ◀", "BT", "BT Clr All", "BT Disc"]
    private static let out = ["USB/BLE", "USB", "BLE"]
    private static let rgb = ["RGB Tog", "RGB On", "RGB Off", "Hue+", "Hue-", "Sat+", "Sat-", "Bri+", "Bri-",
                              "Spd+", "Spd-", "Eff+", "Eff-", "Eff", "Color"]
    private static let bl = ["BL On", "BL Off", "BL Tog", "BL+", "BL-", "BL Cyc", "BL Set"]
    private static let ext = ["Ext Off", "Ext On", "Ext Tog"]

    /// マウス移動・スクロール量（上位 16bit = X, 下位 16bit = Y, 符号付き）を矢印に
    private static func arrow(_ v: UInt32) -> String {
        let x = Int16(truncatingIfNeeded: v >> 16), y = Int16(truncatingIfNeeded: v)
        return (y < 0 ? "↑" : y > 0 ? "↓" : "") + (x < 0 ? "←" : x > 0 ? "→" : "")
    }

    static func label(_ b: Binding, km: KeymapData, host: HostLayout) -> KeyLabel {
        let name = km.behaviors[String(b.behaviorId)] ?? ""
        func layerName(_ id: UInt32) -> String { km.layers.first { $0.id == Int(id) }?.name ?? "L\(id)" }
        func pick(_ t: [String], _ i: UInt32, _ d: String) -> String { Int(i) < t.count ? t[Int(i)] : d }
        switch name {
        case "Key Press": return key(b.param1, host: host)
        case "None": return KeyLabel(main: "", kind: .none)
        case "Transparent": return KeyLabel(main: "▽", kind: .trans)
        case "Momentary Layer": return KeyLabel(main: "MO\n" + layerName(b.param1), kind: .layer)
        case "Toggle Layer": return KeyLabel(main: "TG\n" + layerName(b.param1), kind: .layer)
        case "To Layer": return KeyLabel(main: "TO\n" + layerName(b.param1), kind: .layer)
        case "Sticky Layer": return KeyLabel(main: "SL\n" + layerName(b.param1), kind: .layer)
        case "Layer-Tap":
            var l = key(b.param2, host: host); l.hold = "▾" + layerName(b.param1); return l
        case "Mod-Tap":
            var l = key(b.param2, host: host)
            l.hold = "▾" + (key(b.param1, host: host).main.split(separator: " ").last.map(String.init) ?? "")
            return l
        case "Sticky Key": return KeyLabel(main: "1×" + key(b.param1, host: host).main, kind: .mod)
        case "Key Toggle": return KeyLabel(main: "⇅" + key(b.param1, host: host).main, kind: .mod)
        case "Mouse Key Press":
            let names = ["L", "R", "M", "4", "5"].enumerated().filter { b.param1 & (1 << $0.offset) != 0 }.map { $0.element }
            return KeyLabel(main: "🖱" + names.joined(separator: "+"), kind: .sys)
        case "Bluetooth":
            let s = pick(bt, b.param1, "BT")
            return KeyLabel(main: (b.param1 == 3 || b.param1 == 5) ? "\(s) \(b.param2)" : s, kind: .sys)
        case "Output Selection": return KeyLabel(main: pick(out, b.param1, "Out"), kind: .sys)
        case "Underglow": return KeyLabel(main: pick(rgb, b.param1, "RGB"), kind: .sys)
        case "Backlight": return KeyLabel(main: pick(bl, b.param1, "BL"), kind: .sys)
        case "External Power": return KeyLabel(main: pick(ext, b.param1, "Ext"), kind: .sys)
        // 以下は Studio が表示名を持たず、デバイスツリーのノード名で返ってくるもの
        case "mouse_move": return KeyLabel(main: "🖱" + arrow(b.param1), kind: .sys)
        case "mouse_scroll": return KeyLabel(main: "⇳" + arrow(b.param1), kind: .sys)
        case "z_so_off": return KeyLabel(main: "Off", kind: .sys)
        case "Reset": return KeyLabel(main: "Reset", kind: .sys)
        case "Bootloader": return KeyLabel(main: "Boot", kind: .sys)
        case "Studio Unlock": return KeyLabel(main: "Studio", kind: .sys)
        case "Caps Word": return KeyLabel(main: "CapsWd", kind: .mod)
        case "Key Repeat": return KeyLabel(main: "Rep", kind: .mod)
        case "Grave/Escape": return KeyLabel(main: "Esc\n`", kind: .mod)
        default: return KeyLabel(main: name.isEmpty ? "?" : name, kind: .sys)  // Studio 非対応 behavior（マウス移動等）
        }
    }
}
