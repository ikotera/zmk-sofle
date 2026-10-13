# Layer Viewer（macOS ネイティブ版）

アクティブなレイヤーと押下中のキーを、常に最前面の小窓に表示するメニューバー常駐アプリ。
ブラウザ版（../layer-viewer/）と同じ表示を、Swift（AppKit）だけで実装している。外部ライブラリは使っていない。

- メモリ使用量: 約 20 MB（`footprint` の phys_footprint, 2026-10 時点の実測）
- キーマップは ZMK Studio RPC（USB シリアル）でキーボード本体から読み、`~/Library/Application Support/LayerViewer/keymap.json` に保存する。
- レイヤーと押下キーはファームウェアの `src/layer_report.c` が Raw HID で送る通知を受け取る（USB / Bluetooth）。

計画・仕様・版の履歴は `PLAN.md`、AI エージェント向けの入口は `AGENTS.md`。

## ビルドとインストール

```bash
swift test            # コアの単体テスト
./build.sh            # build/Layer Viewer.app を作る
./build.sh install    # ~/Applications へ入れ替える
```

Xcode のコマンドラインツールが必要。Apple Development の証明書があればそれで署名し、無ければ ad-hoc 署名にする。配布せず自分の Mac で使う前提。

## 使い方

- 初回起動時、左手が USB 接続されていればキーマップを自動で取得する。ZMK Studio アプリを開いているとシリアルポートを使えないので閉じておく。
- Studio でキーマップを変えたら、メニューバーの ⌨ →「キーマップ再取得（USB）」。
- 小窓はドラッグで移動できる。位置は次回起動時も維持される。
- メニューでは、ホスト配列（US / JIS）、Shift 時の文字の表示、サイズ、不透明度、クリック透過、ログイン時に起動を切り替えられる。

## キーリピートの記録

キーリピートが止まらない現象の原因を調べるため、キーボード内部・Mac が受け取った HID・macOS のキーイベントの3つを突き合わせて記録する（仕様は PLAN §4.2）。

- 初回は macOS の「入力監視」の許可を求められる（システム設定 > プライバシーとセキュリティ > 入力監視）。
- 記録先は `~/Library/Logs/LayerViewer/`（メニューの「記録フォルダを開く」）。`events.log` に1行ずつ、異常のときは `incident-*.log` に直前 20 秒の観測を書き出す。
- 現象が起きたら、20 秒以内にメニューの「いま異常が起きた（印を付ける）」を押すと、その時点の観測が残る。
- 記録するのはキーの番号と時刻だけで、入力した文字列は組み立てない。メニューで記録を止められる。
