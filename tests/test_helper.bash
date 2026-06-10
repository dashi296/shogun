#!/usr/bin/env bash
# テスト共通ヘルパー

# リポジトリルートの絶対パス（tests/ の1階層上）
SHOGUN_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SHOGUN_REPO

# bin/ を PATH に追加
export PATH="${SHOGUN_REPO}/bin:${PATH}"

# macOS: util-linux の flock を keg-only パスから追加
if [[ "$(uname -s)" == "Darwin" ]]; then
  export PATH="/opt/homebrew/opt/util-linux/bin:${PATH}"
fi

# js-yaml を確実に解決できるよう NODE_PATH を設定
export NODE_PATH="${SHOGUN_REPO}/node_modules${NODE_PATH:+:$NODE_PATH}"

# テスト用一時プロジェクトを作成（inbox_write 単体テスト用: inbox ディレクトリのみ）
setup_test_project() {
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  export SHOGUN_ROOT="${TEST_PROJECT}"
  mkdir -p "${TEST_PROJECT}/.shogun/queue/inbox"
}

# shogun init 済みのフルプロジェクトを作成（統合テスト用）
init_test_project() {
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  cd "${TEST_PROJECT}"
  shogun init >/dev/null 2>&1
  export SHOGUN_ROOT="${TEST_PROJECT}"
}

# テスト用プロジェクトを削除
teardown_test_project() {
  if [[ -n "${TEST_PROJECT:-}" && -d "${TEST_PROJECT}" ]]; then
    rm -rf "${TEST_PROJECT}"
  fi
}

# YAML ファイルの Node.js 式で値を取得
yaml_query() {
  local file="$1"
  local expr="$2"
  node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${file}', 'utf8')) || {};
${expr}
"
}
