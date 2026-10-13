#!/bin/bash
# 版を上げて commit し、注釈付きタグを付ける（dotfiles/shared-references/dev/versioning.md）。
#
#   scripts/bump_version.sh minor "S1: キーリピートの記録"   # 1.0.0 → 1.1.0
#   scripts/bump_version.sh patch "記録の不具合を修正"        # 1.1.0 → 1.1.1
#
# 版の正本は VERSION（Rust ワークスペースではないため Cargo.toml の代わり）。
# このリポジトリはキーボードの設定と同居しているので、タグは layer-viewer-v<版> にする（PLAN §9 Q2）。
# 先に PLAN.md（§8.2 のステップ行と §10 の版の履歴）を更新し、実装の変更を git add しておく。
# push は別に行う: git push origin main --follow-tags
set -euo pipefail

cd "$(dirname "$0")/.."

part=${1:-}
summary=${2:-}
if [[ ! "$part" =~ ^(major|minor|patch)$ || -z "$summary" ]]; then
  echo "使い方: $0 major|minor|patch \"<要約>\"" >&2
  exit 2
fi

current=$(tr -d '[:space:]' < VERSION)
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION を読めない: '$current'" >&2
  exit 1
fi
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
case $part in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
esac

tag="layer-viewer-v$next"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "タグ $tag は既にある" >&2
  exit 1
fi

echo "$next" > VERSION
git add VERSION
[[ -f PLAN.md ]] && git add PLAN.md
git commit -m "layer-viewer v$next: $summary"
git tag -a "$tag" -m "layer-viewer v$next: $summary"
echo "版: v${current} → v${next}（タグ ${tag}）。push: git push origin main --follow-tags"
