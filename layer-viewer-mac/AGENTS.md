# Layer Viewer

AI エージェント（Claude Code・Codex・Gemini）向けの入口。詳細はすべて PLAN.md にある。

## 最初に読む

1. `PLAN.md`（唯一の正本。目的・仕様・要望・ステップ・版・計測・気づきの台帳）
2. dotfiles の開発規約（ローカル `~/Github/dotfiles/shared-references/dev/`、クラウド `~/dotfiles/shared-references/dev/`）: `workflow.md`・`principles.md`・`versioning.md`。読めない環境では下の「規則の要約」に従う。

## 規則の要約

- 要望は PLAN §7 に転記し、§8 のステップに割り当ててから実装する。チャットでの依頼も転記する。
- コア（`Sources/LayerViewerCore`、画面・OS の機能に依存しない）を先に作り、単体テストで固める。
- 省資源: UI のスレッドで重い処理をしない。性能に関わる変更は計測して PLAN §11 に記録する。
- ステップを完了するたびに版を上げ（`scripts/bump_version.sh minor|patch|major "<要約>"`）、報告の先頭に `版: vX → vY` と書く。版は小窓の右上とメニューに出る。
- PLAN.md を更新してから commit し、`git push origin main --follow-tags` する。タグは `layer-viewer-v<版>`。push 先のリポジトリとブランチを報告する。
- 他のプロジェクトにも役立つ気づきは PLAN §12 に1行書き、たまったら knowledge-base へ distill する。
- ファームウェア側の送信は `../src/layer_report.c`。レポートの形式を変えるときは両方を合わせる。

## コマンド

```bash
swift test                       # コアの単体テスト
swift build                      # デバッグビルド
./build.sh                       # build/Layer Viewer.app を作る（VERSION の版、Apple Development で署名）
./build.sh install               # ~/Applications へ入れ替える
scripts/bump_version.sh minor "S<n>: <要約>"   # 版を上げて commit・タグ
```
