#!/usr/bin/env bash
# 使い方: .github/scripts/release.sh [--dry-run] 0.0.2
set -euo pipefail

DRY_RUN=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

VERSION="${1:?使い方: $0 [--dry-run] <version> (例: 0.0.2)}"
TAG="v${VERSION}"

# semver バリデーション
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: 不正なバージョン形式: ${VERSION}（例: 0.0.2）" >&2
  exit 1
}

# main ブランチにいることを確認
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${current_branch}" != "main" ]]; then
  echo "ERROR: main ブランチにいません（現在: ${current_branch}）" >&2
  exit 1
fi

# クリーンな状態であることを確認
git diff --quiet && git diff --cached --quiet || {
  echo "ERROR: コミットされていない変更があります" >&2
  exit 1
}

# タグ重複チェック（git commit より前に行い、孤立コミットを防ぐ）
if git tag | grep -qx "${TAG}"; then
  echo "ERROR: ローカルにタグ ${TAG} がすでに存在します" >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/${TAG}" | grep -q .; then
  echo "ERROR: リモートにタグ ${TAG} がすでに存在します" >&2
  exit 1
fi

# テスト実行
echo "テストを実行します..."
npm run test:unit || {
  echo "ERROR: テストが失敗しました。リリースを中止します。" >&2
  exit 1
}

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[DRY RUN] リリース内容のプレビュー:"
  echo "  バージョン : ${VERSION}"
  echo "  タグ       : ${TAG}"
  echo "  ブランチ   : ${current_branch}"
  echo "[DRY RUN] 実際の変更は行いません。"
  exit 0
fi

# package.json のバージョンを更新（Node.js を使い macOS/Linux 両対応）
node -e "
  const fs = require('fs');
  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  pkg.version = '${VERSION}';
  fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
npm install --package-lock-only
git add package.json package-lock.json
# すでに同じバージョンの場合は差分なし → コミットをスキップしてタグ作成へ進む
if ! git diff --cached --quiet; then
  git commit -m "chore: bump version to ${VERSION}"
else
  echo "package.json はすでに ${VERSION} です。バージョンバンプコミットをスキップします。"
fi

git tag "${TAG}"
git push origin main
git push origin "${TAG}"

echo "Released ${TAG}"
