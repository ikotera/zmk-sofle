# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

プロジェクト概要
- 本リポジトリは、カスタム分割キーボード Sofle（Eyelash Sofle, nRF52840）向けの ZMK ファームウェアです。Zephyr のカスタムボード定義とユーザー設定／キーマップを含みます。
- CI は左右それぞれのファームウェアをビルドし、別ワークフローでキーマップ図（SVG）を生成します。

よく使うコマンド

ローカルの west ワークスペース初期化（クローン直後の一度きり）
```bash path=null start=null
# リポジトリ直下で実行
west init -l config
west update
west zephyr-export
# ZMK アプリが取得できているか確認
west list zmk
```

ファームウェアのビルド（左右それぞれ）
```bash path=null start=null
# 左手（nice_view ディスプレイシールド付き）
west build -s zmk/app -b eyelash_sofle_left  -d build/left  -- -DZMK_CONFIG=$PWD/config -DSHIELD=nice_view

# 右手（nice_view ディスプレイシールド付き）
west build -s zmk/app -b eyelash_sofle_right -d build/right -- -DZMK_CONFIG=$PWD/config -DSHIELD=nice_view
```

クリーンリビルド（pristine）
```bash path=null start=null
# 例：左手をクリーンしてから再ビルド
west build -d build/left -t pristine && \
  west build -s zmk/app -b eyelash_sofle_left -d build/left -- -DZMK_CONFIG=$PWD/config -DSHIELD=nice_view
```

成果物（UF2）
- ボード defconfig で CONFIG_BUILD_OUTPUT_UF2=y が有効なため、UF2 が生成されます。
- 成功後は build/<side>/zephyr/*.uf2 を確認してください。
- 書き込みは、基板をブートローダーモードでマスストレージとしてマウントし、UF2 をコピーします。

キーマップ図の生成（ローカル・任意）
```bash path=null start=null
# 事前に keymap-drawer を用意（例：pipx install keymap-drawer）
keymap-drawer draw \
  config/eyelash_sofle.keymap \
  -o keymap-drawer/eyelash_sofle.svg \
  -c keymap_drawer.config.yaml
```

CI に関する補足
- ファームウェアビルド: .github/workflows/build.yml は zmkfirmware/zmk の build-user-config ワークフローを利用し、build.yaml を参照して左右（nice_view シールド）をビルドします。keymap-drawer/** を除く変更で起動し、成果物はワークフローの実行に添付されます。
- キーマップ図: .github/workflows/draw.yml は config/**、keymap_drawer.config.yaml、または当該ワークフローの変更で起動し、SVG を生成してコミットします。

アーキテクチャ概要

Zephyr モジュールとボード検出
- zephyr/module.yml の board_root: . により、boards/arm/eyelash_sofle 配下のカスタムボードが Zephyr に検出されます。
- config/west.yml は ZMK（zmkfirmware/zmk@main）を取り込み、app/west.yml を import します。self.path は config のため、west init -l config で本リポジトリがマニフェストとして機能します。

カスタム分割ボード（Eyelash Sofle）
- ボード ID: eyelash_sofle_left / eyelash_sofle_right（Kconfig.board）。論理的な共有ボード識別子は "eyelash_sofle"（Kconfig.defconfig）。
- 左手（eyelash_sofle_left_defconfig）: USB と BLE を有効、ディスプレイ有効、中央（central）ロール、UF2 出力、外部電源、エンコーダ、ポインティング、バックライト等を設定。
- 右手（eyelash_sofle_right_defconfig）: BLE、UF2 出力、外部電源を有効。USB は無効で周辺（peripheral）として動作。

DeviceTree 概要（boards/arm/eyelash_sofle 配下）
- eyelash_sofle.dtsi では以下を定義:
  - 行列スキャン（kscan0）: GPIO マトリクス、col2row、行/列ピンを明示。
  - 物理レイアウト: eyelash_sofle-layouts.dtsi で物理キー配置を定義し、default_transform でマトリクス→物理の対応を規定。
  - ロータリーエンコーダ（left_encoder, ALPS EC11）: センサーとして公開し、キーマップからバインド可能。左右オーバレイで有効化。
  - 外部電源（ext-power）、VDDH バッテリ（vbatt）、PWM バックライト（pwm0）、WS2812 アンダーグロー（spi3, RGB チャンネルマッピング）。
  - USB CDC ACM、アンダーグロー/ディスプレイ用 SPI と pinctrl、ディスプレイ SPI の CS。
- 側オーバレイ:
  - eyelash_sofle_left.dts: 左エンコーダを有効化し、左側の列ピンを設定。
  - eyelash_sofle_right.dts: 列マッピングを調整し、右手用に default_transform の列オフセットを付与。

キーマップと挙動
- 主キーマップ: config/eyelash_sofle.keymap にレイヤ、コンボ、エンコーダのスクロール動作（scroll_encoder）、ポインティング/マウス移動（&mmv, &msc）とその加速やタイミング調整を定義。
- コンボ: ソフトオフ（hold-time-ms = 2000）と studio_unlock など。上位レイヤに Bluetooth/出力切替、リセット、ブートローダ起動などを配置。
- ZMK 設定: config/eyelash_sofle.conf で Studio、ディスプレイ、RGB アンダーグロー（自動オフ含む）、ポインティング、バックライト、デバウンス、ソフトオフ等を有効化。
- 物理レイアウトメタデータ: config/eyelash_sofle.json は外部ツール向けにキーボード形状を記述。

README の要点
- 追加項目: zmk-studio 対応、消費電力の調整、ソフトオフ（Q+S+Z を約 2 秒で深いスリープ、持ち運び時に有効。復帰はリセットスイッチ）、右手ディスプレイの GIF を削除して消費電力削減。2025-08-22 以前のファームウェアは更新推奨。

ルールとパス構成
- build.yaml を基準に左右 + nice_view シールドをビルドします。シールドや機能を変える場合は、west のビルドフラグと build.yaml の両方を更新してください。
- ディレクトリの役割は明確に分離:
  - ボード／ハード記述: boards/arm/eyelash_sofle/**
  - ユーザー設定・キーマップ・マニフェスト: config/**
  - キーマップ可視化: keymap-drawer/** と keymap_drawer.config.yaml

トラブルシューティング（本リポジトリ特有）
- ボードが見つからない場合: west init -l config と west update を実行済みか、zephyr/module.yml の board_root: . が維持されているか確認してください。
- ディスプレイ関連でビルド失敗: -DSHIELD=nice_view を付与しているか、config/eyelash_sofle.conf で CONFIG_ZMK_DISPLAY が意図通りか確認してください。
