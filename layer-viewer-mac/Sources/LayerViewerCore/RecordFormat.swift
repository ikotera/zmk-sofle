// 記録ファイルに書く1行の形。ファイルへの書き込みはアプリ側で行う。
import Foundation

public enum RecordFormat {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func timestamp(_ date: Date) -> String { clock.string(from: date) }

    /// 異常の1行（events.log に追記する）
    public static func line(_ f: Finding, at date: Date) -> String {
        "\(timestamp(date)) " + describe(f)
    }

    public static func describe(_ f: Finding) -> String {
        switch f {
        case let .repeatBurst(keyCode, count, _, verdict):
            let key = KeyCodes.usage(forKeyCode: keyCode).map(KeyCodes.name(usage:)) ?? "keyCode \(keyCode)"
            return "異常リピート: \(key) を \(count) 回以上リピート / 判定: \(verdict.text)"
        case let .firmwareLongHold(position, usage, seconds):
            let key = usage.map(KeyCodes.name(usage:)) ?? "?"
            return String(format: "長押し（キーボード内部）: 位置 %d（%@）が %.1f 秒以上押下中", position, key, seconds)
        case let .hidLongHold(usage, seconds):
            return String(format: "長押し（Mac の HID）: %@ が %.1f 秒以上押下中", KeyCodes.name(usage: usage), seconds)
        case .userMark:
            return "利用者の印"
        }
    }

    /// 直近の観測の1行（incident ファイルに書き出す）。t0 は異常の時刻で、そこからの相対秒を付ける
    public static func describe(_ e: TimedEvent, relativeTo t0: Double) -> String {
        let rel = String(format: "%+8.3f", e.time - t0)
        switch e.event {
        case let .firmware(pressed, mask):
            let keys = pressed.sorted().map(String.init).joined(separator: ",")
            return "\(rel) キーボード  押下中の位置=[\(keys)] レイヤー=0x\(String(mask, radix: 16))"
        case let .hid(usage, down):
            return "\(rel) Mac HID     \(KeyCodes.name(usage: usage)) \(down ? "押下" : "解放")"
        case let .os(keyCode, down, autorepeat):
            let key = KeyCodes.usage(forKeyCode: keyCode).map(KeyCodes.name(usage:)) ?? "keyCode \(keyCode)"
            return "\(rel) macOS       \(key) \(down ? (autorepeat ? "リピート" : "keyDown") : "keyUp")"
        case .mark:
            return "\(rel) 利用者の印"
        }
    }
}
