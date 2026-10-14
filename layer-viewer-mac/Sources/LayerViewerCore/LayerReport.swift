// ファームウェア（src/layer_report.c）が Raw HID で送るレポートの解釈
import Foundation

public struct KeyboardDiag: Equatable {
    /// 前回の送信以降のシステムワークキューの最大の遅れ（ms）
    public var maxQueueDelayMs: Int
    /// 最後の設定の保存にかかった時間（ms）
    public var lastSaveMs: Int
    /// 設定の保存の回数（起動からの累計の下位 8 bit）
    public var saveCount: Int
    /// 最後に保存した設定の名前の先頭 3 文字
    public var lastSaveName: String

    public init(maxQueueDelayMs: Int, lastSaveMs: Int, saveCount: Int, lastSaveName: String) {
        self.maxQueueDelayMs = maxQueueDelayMs; self.lastSaveMs = lastSaveMs
        self.saveCount = saveCount; self.lastSaveName = lastSaveName
    }
}

public struct LayerReport: Equatable {
    public var layerMask: UInt32
    public var pressed: Set<Int>
    /// v3 以降の計測値
    public var diag: KeyboardDiag?

    /// 先頭 0x4C のレポートを解釈する。違えば nil
    public static func parse<C: Collection>(_ r: C) -> LayerReport? where C.Element == UInt8, C.Index == Int {
        let b = Array(r)
        guard b.count >= 8, b[0] == 0x4C else { return nil }
        let version = b[1]
        let mask = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        // 押下中のキーのビットマップ: v2 は [8..31]、v3 は [8..23]（[24..] は計測値）
        let bitmapEnd = version >= 3 ? min(24, b.count) : b.count
        var pressed = Set<Int>()
        if version >= 2 {
            for i in 8..<bitmapEnd where b[i] != 0 {
                for bit in 0..<8 where b[i] & (1 << bit) != 0 { pressed.insert((i - 8) * 8 + bit) }
            }
        }
        var diag: KeyboardDiag?
        if version >= 3, b.count >= 32 {
            let name = String(decoding: b[29..<32].prefix { $0 != 0 }, as: UTF8.self)
            diag = KeyboardDiag(maxQueueDelayMs: Int(b[24]) | Int(b[25]) << 8,
                                lastSaveMs: Int(b[26]) | Int(b[27]) << 8,
                                saveCount: Int(b[28]), lastSaveName: name)
        }
        return LayerReport(layerMask: mask | 1, pressed: pressed, diag: diag)
    }
}
