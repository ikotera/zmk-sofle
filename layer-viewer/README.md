# Layer Viewer

分割キーボード（Eyelash Sofle / ZMK）の **いまアクティブなレイヤー** を画面に表示する練習用ツール。
修飾付きのキーは「Shift+2」ではなく、実際に入力される文字（例: `@`）で表示する。

## 仕組み

| 情報 | 取得元 |
| --- | --- |
| キー配列・各レイヤーの割り当て | ZMK Studio RPC（Remote Procedure Call）を Web Serial で読む（左手 USB 接続時のみ。取得後はブラウザに保存） |
| アクティブなレイヤー | ファームウェアの `src/layer_report.c` が Raw HID（[zmk-raw-hid](https://github.com/zzeneg/zmk-raw-hid)）でレイヤー変更を通知し、WebHID で受信（USB / Bluetooth） |

## 使い方

1. 左手に Raw HID 対応ファームウェア（`build.yaml` の `raw_hid_adapter` 付きビルド）を書き込む。
2. ローカルで配信して Chrome / Edge で開く（WebHID / Web Serial は `localhost` か HTTPS が必要）。

   ```bash
   python3 -m http.server 8000 -d layer-viewer
   # → http://localhost:8000/
   ```

3. 左手を USB 接続し「キーマップ取得（USB）」→ ZMK Studio のシリアルポートを選択。
   ZMK Studio アプリを開いているとポートが使えないので閉じておく。Studio でキーマップを変えたら再取得する。
4. 「レイヤー通知に接続」→ キーボードを選択。以後は自動再接続する。
5. 「最前面ウィンドウ」で常に手前に出る小窓（Document Picture-in-Picture）に切り替えられる。

- ホスト側の配列（macOS の入力ソースが US か JIS か）を右上で選ぶ。同じ Shift+2 でも US は `@`、JIS は `"` になる。
- 透過（`&trans`）のキーは下のレイヤーの割り当てを薄く表示する。
- レイヤー名をクリックすると手動でプレビューできる（通知を受けると解除）。

## Raw HID レポート形式

32 バイト、先頭 `0x4C`（'L'）。`[1]` バージョン、`[2]` 最上位アクティブレイヤーの index、`[4..7]` レイヤー状態ビットマスク（layer id 単位、little endian）。
ホストから先頭 `0x4C` の出力レポートを送ると現在の状態を返す。
