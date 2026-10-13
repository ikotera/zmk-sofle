// キーマップの解決（どのキー位置が、いまどの割り当てになっているか）。描画と記録の両方で使う。
import Foundation

public extension KeymapData {
    /// アクティブなレイヤーの index（下から順）。layer 0 は常にアクティブ
    func activeIndices(layerMask: UInt32) -> [Int] {
        layers.indices.filter { $0 == 0 || (layers[$0].id < 32 && layerMask >> UInt32(layers[$0].id) & 1 == 1) }
    }

    func behaviorName(_ b: Binding) -> String { behaviors[String(b.behaviorId)] ?? "" }

    /// ZMK と同じ順で、上のアクティブなレイヤーから透過（Transparent）を飛ばして割り当てを探す
    func resolve(position: Int, layerMask: UInt32) -> (binding: Binding, layerIndex: Int)? {
        for idx in activeIndices(layerMask: layerMask).reversed() {
            guard position < layers[idx].bindings.count else { continue }
            let b = layers[idx].bindings[position]
            if behaviorName(b) == "Transparent" && idx != 0 { continue }
            return (b, idx)
        }
        return nil
    }

    /// キー位置を押したときにホストへ送られる HID Usage（キーボードページ）。文字キー以外は nil
    func hidUsage(position: Int, layerMask: UInt32) -> Int? {
        guard let (b, _) = resolve(position: position, layerMask: layerMask) else { return nil }
        let code: UInt32
        switch behaviorName(b) {
        case "Key Press": code = b.param1
        case "Layer-Tap", "Mod-Tap": code = b.param2  // タップ時のキー
        default: return nil
        }
        guard (code >> 16) & 0xff == 0x07 else { return nil }
        return Int(code & 0xffff)
    }
}
