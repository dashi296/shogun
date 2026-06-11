#!/usr/bin/env bash
# 使い方: ./scripts/release.sh 0.0.2
set -euo pipefail

VERSION="${1:?使い方: $0 <version> (例: 0.0.2)}"
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

# package.json のバージョンを更新（Node.js を使い macOS/Linux 両対応）
node -e "
  const fs = require('fs');
  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  pkg.version = '${VERSION}';
  fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
npm install --package-lock-only --silent
git add package.json package-lock.json
git commit -m "chore: bump version to ${VERSION}"

git tag "${TAG}"
git push origin main
git push origin "${TAG}"

echo "Released ${TAG}"
