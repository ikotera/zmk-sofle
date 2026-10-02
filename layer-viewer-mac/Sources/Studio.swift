// ZMK Studio RPC（USB シリアル）でキーマップを読み出す最小実装。
// 依存を増やさないため、必要なメッセージだけを手書きの protobuf で扱う。
import Foundation

// MARK: - データモデル（取得結果。JSON でキャッシュする）

struct KeyAttr: Codable {
    var width = 0, height = 0, x = 0, y = 0, r = 0, rx = 0, ry = 0  // 1/100 キー単位, r は 1/100 度
}

struct Binding: Codable {
    var behaviorId = 0
    var param1: UInt32 = 0
    var param2: UInt32 = 0
}

struct Layer: Codable {
    var id = 0
    var name = ""
    var bindings: [Binding] = []
}

struct KeymapData: Codable {
    var savedAt = Date()
    var keys: [KeyAttr] = []
    var layers: [Layer] = []
    var behaviors: [String: String] = [:]  // behavior id → 表示名

    static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LayerViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keymap.json")
    }

    static func loadCache() -> KeymapData? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(KeymapData.self, from: data)
    }

    func saveCache() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.cacheURL) }
    }
}

// MARK: - protobuf（varint / length-delimited のみ）

struct ProtoField {
    let number: Int
    let varint: UInt64
    let bytes: Data
}

enum Proto {
    static func parse(_ data: Data) throws -> [ProtoField] {
        var out: [ProtoField] = []
        var i = data.startIndex
        func varint() throws -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < data.endIndex else { throw StudioError.decode }
                let b = data[i]; i += 1
                v |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
        }
        while i < data.endIndex {
            let tag = try varint()
            let num = Int(tag >> 3)
            switch tag & 7 {
            case 0: out.append(ProtoField(number: num, varint: try varint(), bytes: Data()))
            case 2:
                let len = Int(try varint())
                guard i + len <= data.endIndex else { throw StudioError.decode }
                out.append(ProtoField(number: num, varint: 0, bytes: data[i..<i + len]))
                i += len
            case 5: i += 4
            case 1: i += 8
            default: throw StudioError.decode
            }
        }
        return out
    }

    static func packedVarints(_ data: Data) throws -> [UInt64] {
        // packed repeated は「varint の連続」なので、フィールド番号 1 の列として読む
        var out: [UInt64] = []
        var i = data.startIndex
        while i < data.endIndex {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                let b = data[i]; i += 1
                v |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            out.append(v)
        }
        return out
    }

    static func zigzag(_ v: UInt64) -> Int { Int(Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))) }

    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7f); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func field(_ n: Int, varint v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    static func field(_ n: Int, bytes b: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(b.count)) + b }
}

extension Array where Element == ProtoField {
    func first(_ n: Int) -> ProtoField? { first { $0.number == n } }
    func all(_ n: Int) -> [ProtoField] { filter { $0.number == n } }
}

enum StudioError: LocalizedError {
    case noPort, busy(String), timeout, decode, locked, rpc(String)
    var errorDescription: String? {
        switch self {
        case .noPort: return "キーボードのシリアルポートが見つかりません（左手を USB 接続してください）"
        case .busy(let p): return "\(p) を開けません（ZMK Studio アプリを閉じてください）"
        case .timeout: return "キーボードから応答がありません"
        case .decode: return "応答を解釈できません"
        case .locked: return "Studio がロック中です（studio_unlock を押してください）"
        case .rpc(let m): return m
        }
    }
}

// MARK: - シリアル接続と RPC

final class StudioClient {
    private let fd: Int32
    private var nextId: UInt64 = 1
    private var rx: [UInt8] = []

    private static let SOF: UInt8 = 0xAB, ESC: UInt8 = 0xAC, EOF: UInt8 = 0xAD

    init(path: String) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw StudioError.busy(path) }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close(fd) }

    /// サブシステム番号（3=core, 4=behaviors, 5=keymap）と、その Request の中身を送り、Response の中身を返す
    func call(subsystem: Int, _ body: [UInt8], timeout: Double = 2) throws -> [ProtoField] {
        let id = nextId; nextId += 1
        let req = Proto.field(1, varint: id) + Proto.field(subsystem, bytes: body)
        var frame: [UInt8] = [Self.SOF]
        for b in req {
            if b == Self.SOF || b == Self.ESC || b == Self.EOF { frame.append(Self.ESC) }
            frame.append(b)
        }
        frame.append(Self.EOF)
        guard write(fd, frame, frame.count) == frame.count else { throw StudioError.rpc("送信に失敗しました") }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while let msg = takeFrame() {
                // Response { request_response = 1 | notification = 2 }
                guard let rr = try Proto.parse(msg).first(1) else { continue }
                let fields = try Proto.parse(rr.bytes)
                guard fields.first(1)?.varint ?? 0 == id else { continue }
                if let meta = fields.first(2) {
                    let m = try Proto.parse(meta.bytes)
                    if m.first(2)?.varint == 1 { throw StudioError.locked }
                    throw StudioError.rpc("RPC エラー")
                }
                guard let sub = fields.first(subsystem) else { throw StudioError.decode }
                return try Proto.parse(sub.bytes)
            }
            let remain = deadline.timeIntervalSinceNow
            guard remain > 0 else { throw StudioError.timeout }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, Int32(remain * 1000)) > 0 {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &buf, buf.count)
                if n > 0 { rx += buf[0..<n] }
            }
        }
    }

    /// 受信バッファから 1 フレーム取り出してエスケープを外す
    private func takeFrame() -> Data? {
        guard let start = rx.firstIndex(of: Self.SOF) else { rx.removeAll(); return nil }
        var out: [UInt8] = []
        var i = start + 1
        while i < rx.count {
            let b = rx[i]
            if b == Self.ESC {
                guard i + 1 < rx.count else { return nil }
                out.append(rx[i + 1]); i += 2; continue
            }
            if b == Self.EOF {
                rx.removeSubrange(0...i)
                return Data(out)
            }
            if b == Self.SOF { rx.removeSubrange(0..<i); return takeFrame() }
            out.append(b); i += 1
        }
        return nil
    }

    // MARK: キーマップ一式の取得

    static func fetchKeymap() throws -> KeymapData {
        let ports = (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
            .filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 } ?? []
        guard !ports.isEmpty else { throw StudioError.noPort }
        var lastError: Error = StudioError.noPort
        for port in ports {
            do {
                let c = try StudioClient(path: port)
                _ = try c.call(subsystem: 3, Proto.field(1, varint: 1), timeout: 1)  // core.get_device_info で疎通確認
                return try c.readKeymap()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func readKeymap() throws -> KeymapData {
        var km = KeymapData()

        // keymap.get_physical_layouts = 6 → PhysicalLayouts { active_layout_index = 1, layouts = 2 }
        let pl = try call(subsystem: 5, Proto.field(6, varint: 1))
        guard let pls = pl.first(6) else { throw StudioError.decode }
        let layouts = try Proto.parse(pls.bytes)
        let active = Int(layouts.first(1)?.varint ?? 0)
        let layoutList = layouts.all(2)
        guard active < layoutList.count else { throw StudioError.decode }
        for k in try Proto.parse(layoutList[active].bytes).all(2) {
            let f = try Proto.parse(k.bytes)
            func z(_ n: Int) -> Int { Proto.zigzag(f.first(n)?.varint ?? 0) }
            km.keys.append(KeyAttr(width: z(1), height: z(2), x: z(3), y: z(4), r: z(5), rx: z(6), ry: z(7)))
        }

        // keymap.get_keymap = 1 → Keymap { layers = 1 }
        let kr = try call(subsystem: 5, Proto.field(1, varint: 1))
        guard let kmf = kr.first(1) else { throw StudioError.decode }
        for (i, lf) in try Proto.parse(kmf.bytes).all(1).enumerated() {
            let f = try Proto.parse(lf.bytes)
            var layer = Layer()
            layer.id = Int(f.first(1)?.varint ?? 0)
            layer.name = String(decoding: f.first(2)?.bytes ?? Data(), as: UTF8.self)
            if layer.name.isEmpty { layer.name = "Layer \(i)" }
            for bf in f.all(3) {
                let b = try Proto.parse(bf.bytes)
                layer.bindings.append(Binding(
                    behaviorId: Proto.zigzag(b.first(1)?.varint ?? 0),
                    param1: UInt32(truncatingIfNeeded: b.first(2)?.varint ?? 0),
                    param2: UInt32(truncatingIfNeeded: b.first(3)?.varint ?? 0)))
            }
            km.layers.append(layer)
        }

        // behaviors.list_all_behaviors = 1 → { behaviors = 1 (packed) }
        let lb = try call(subsystem: 4, Proto.field(1, varint: 1))
        guard let lbf = lb.first(1) else { throw StudioError.decode }
        var ids: [UInt64] = []
        for f in try Proto.parse(lbf.bytes).all(1) {
            ids += f.bytes.isEmpty ? [f.varint] : try Proto.packedVarints(f.bytes)
        }
        // behaviors.get_behavior_details = 2 { behavior_id = 1 } → { display_name = 2 }
        for id in ids {
            let d = try call(subsystem: 4, Proto.field(2, bytes: Proto.field(1, varint: id)))
            guard let df = d.first(2) else { continue }
            let name = try Proto.parse(df.bytes).first(2)?.bytes ?? Data()
            km.behaviors[String(id)] = String(decoding: name, as: UTF8.self)
        }

        km.savedAt = Date()
        return km
    }
}
