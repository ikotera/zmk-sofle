# Layer Viewer（macOS ネイティブ版）

アクティブなレイヤーと押下中のキーを、常に最前面の小窓に表示するメニューバー常駐アプリ。
ブラウザ版（../layer-viewer/）と同じ表示を、Swift（AppKit）だけで実装している。外部ライブラリは使っていない。

- メモリ使用量: 約 20 MB（`footprint` の phys_footprint, 2026-10 時点の実測）
- キーマップは ZMK Studio RPC（USB シリアル）でキーボード本体から読み、`~/Library/Application Support/LayerViewer/keymap.json` に保存する。
- レイヤーと押下キーはファームウェアの `src/layer_report.c` が Raw HID で送る通知を受け取る（USB / Bluetooth）。

## ビルドとインストール

```bash
./build.sh            # build/Layer Viewer.app を作る
./build.sh install    # ~/Applications へコピー
```

Xcode のコマンドラインツール（swiftc）が必要。ad-hoc 署名なので、配布せず自分の Mac で使う前提。

## 使い方

- 初回起動時、左手が USB 接続されていればキーマップを自動で取得する。ZMK Studio アプリを開いているとシリアルポートを使えないので閉じておく。
- Studio でキーマップを変えたら、メニューバーの ⌨ →「キーマップ再取得（USB）」。
- 小窓はドラッグで移動できる。位置は次回起動時も維持される。
- メニューでは、ホスト配列（US / JIS）、Shift 時の文字の表示、サイズ、不透明度、クリック透過、ログイン時に起動を切り替えられる。
