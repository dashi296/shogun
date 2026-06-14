#!/usr/bin/env bash
# Shogun インストーラー
# 使い方: curl -fsSL https://github.com/dashi296/shogun/releases/latest/download/install.sh | bash
set -euo pipefail

# ─── カラー & ログ ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WARNINGS=0
ERRORS=0

log_ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; WARNINGS=$((WARNINGS+1)); }
log_err()  { echo -e "${RED}[ERR]${NC}   $*"; ERRORS=$((ERRORS+1)); }
log_info() { echo -e "${BLUE}[INFO]${NC}  $*"; }

# ─── インストール先・リポジトリURL・バージョン ────────────
INSTALL_DIR="${HOME}/.local/share/shogun"
BIN_DIR="${HOME}/.local/bin"
REPO_URL="https://github.com/dashi296/shogun"
INSTALL_VERSION="__VERSION__"   # GitHub Actions がリリース時に実バージョンへ置換

# GitHub Releases からダウンロードされた install.sh 以外での実行を防ぐ
# SHOGUN_DEV_INSTALL=1 を設定することで開発時のローカルテストをバイパスできる
[[ "${INSTALL_VERSION}" == "__VERSION__" && -z "${SHOGUN_DEV_INSTALL:-}" ]] && {
  log_err "このスクリプトはバージョン置換前です。"
  log_err "GitHub Releases からダウンロードして実行してください:"
  log_err "  curl -fsSL https://github.com/dashi296/shogun/releases/latest/download/install.sh | bash"
  log_err "開発用にローカルテストする場合: SHOGUN_DEV_INSTALL=1 ./install.sh"
  exit 1
}
[[ "${INSTALL_VERSION}" == "__VERSION__" ]] && INSTALL_VERSION="main"

# ════════════════════════════════════════════════════════════
# STEP 1: 依存ツールチェック
# ════════════════════════════════════════════════════════════
echo ""
log_info "STEP 1: 依存ツールチェック"
echo "──────────────────────────────────────────"

# OS 判定
OS="$(uname -s)"

# tmux
if command -v tmux &>/dev/null; then
  log_ok "tmux: $(tmux -V)"
else
  if [[ "$OS" == "Linux" ]]; then
    log_info "tmux が見つかりません。apt-get でインストールします..."
    if sudo apt-get install -y tmux 2>/dev/null; then
      log_ok "tmux: インストール完了"
    else
      log_warn "tmux: インストールに失敗しました。手動でインストールしてください。"
    fi
  else
    # macOS
    log_warn "tmux が見つかりません。以下のコマンドでインストールしてください:"
    log_warn "  brew install tmux"
  fi
fi

# node（必須）
if command -v node &>/dev/null; then
  log_ok "node: $(node --version)"
else
  log_err "node が見つかりません。Node.js は必須です。"
  log_err "  https://nodejs.org/ からインストールしてください。"
fi

# claude
if command -v claude &>/dev/null; then
  log_ok "claude: $(claude --version 2>/dev/null | head -1 || echo 'インストール済み')"
else
  log_warn "claude が見つかりません。以下の URL からインストールしてください:"
  log_warn "  https://claude.ai/code"
fi

# fswatch (macOS) / inotifywait (Linux)
if [[ "$OS" == "Darwin" ]]; then
  if command -v fswatch &>/dev/null; then
    log_ok "fswatch: $(fswatch --version 2>/dev/null | head -1 || echo 'インストール済み')"
  else
    log_warn "fswatch が見つかりません。以下のコマンドでインストールしてください:"
    log_warn "  brew install fswatch"
  fi
else
  # Linux
  if command -v inotifywait &>/dev/null; then
    log_ok "inotifywait: インストール済み"
  else
    log_info "inotifywait が見つかりません。apt-get でインストールします..."
    if sudo apt-get install -y inotify-tools 2>/dev/null; then
      log_ok "inotifywait: インストール完了"
    else
      log_warn "inotify-tools: インストールに失敗しました。手動でインストールしてください。"
      log_warn "  sudo apt-get install inotify-tools"
    fi
  fi
fi

# flock（macOS のみチェック。Linux はプリインストール済み）
if [[ "$OS" == "Darwin" ]]; then
  FLOCK_KEG="/opt/homebrew/opt/util-linux/bin"
  if command -v flock &>/dev/null; then
    log_ok "flock: インストール済み"
  elif [[ -x "${FLOCK_KEG}/flock" ]]; then
    log_ok "flock: インストール済み (keg-only: ${FLOCK_KEG})"
  else
    log_warn "flock が見つかりません。以下のコマンドでインストールしてください:"
    log_warn "  brew install util-linux"
  fi
fi

# ERR がある場合は終了
if [[ "$ERRORS" -gt 0 ]]; then
  echo ""
  echo -e "${RED}必須の依存ツールが不足しています。上記のエラーを解消してから再実行してください。${NC}"
  exit 1
fi

# ════════════════════════════════════════════════════════════
# STEP 2: フレームワーク本体のインストール
# ════════════════════════════════════════════════════════════
echo ""
log_info "STEP 2: フレームワーク本体のインストール"
echo "──────────────────────────────────────────"

# clone と npm install を一時ディレクトリで完了してから既存ディレクトリと置き換えるヘルパー
# （npm install まで成功しない限り既存インストールを消さない）
_fresh_install() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if git clone --branch "${INSTALL_VERSION}" --depth 1 "${REPO_URL}" "${tmp_dir}"; then
    if (cd "${tmp_dir}" && npm install --omit=dev --silent); then
      # エンドユーザーに不要なファイルを削除する（tests/・docs/）
      # _fresh_install は新規/再インストール両方で呼ばれるため、ここで削除すれば全パスを網羅できる
      rm -rf "${tmp_dir}/tests" "${tmp_dir}/docs"
      rm -rf "${INSTALL_DIR}"
      mv "${tmp_dir}" "${INSTALL_DIR}"
      log_ok "フレームワーク ${INSTALL_VERSION} を再インストールしました"
    else
      rm -rf "${tmp_dir}"
      log_err "npm install に失敗しました。既存のインストールを維持します。"
      exit 1
    fi
  else
    rm -rf "${tmp_dir}"
    log_err "再インストールに失敗しました。既存のインストールを維持します。"
    exit 1
  fi
}

# shallow clone の unshallow を試みたうえでタグ切り替えを行うヘルパー
# 失敗時は 1 を返す
_try_git_upgrade() {
  if git -C "${INSTALL_DIR}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    git -C "${INSTALL_DIR}" fetch --unshallow --quiet || return 1
  fi
  git -C "${INSTALL_DIR}" fetch --tags --quiet \
    && git -C "${INSTALL_DIR}" checkout "${INSTALL_VERSION}" --quiet
}

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  log_info "既存のインストールを ${INSTALL_VERSION} に更新します: ${INSTALL_DIR}"

  if _try_git_upgrade; then
    # git checkout で tests/・docs/ が復活するため、アップグレード後にも削除する
    # sparse-checkout の代わりにこの削除処理で upgrade 後の再出現を防ぐ
    rm -rf "${INSTALL_DIR}/tests" "${INSTALL_DIR}/docs"
    log_ok "フレームワークを ${INSTALL_VERSION} に更新しました"
  else
    log_warn "git によるバージョン切り替えに失敗しました。フレッシュインストールを試みます..."
    _fresh_install
  fi
else
  log_info "Shogun ${INSTALL_VERSION} をインストールします: ${INSTALL_DIR}"
  mkdir -p "$(dirname "${INSTALL_DIR}")"
  git clone --branch "${INSTALL_VERSION}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
  # エンドユーザーに不要なファイルを削除する（tests/・docs/）
  rm -rf "${INSTALL_DIR}/tests" "${INSTALL_DIR}/docs"
  log_ok "フレームワーク ${INSTALL_VERSION} をインストールしました"
fi

# ════════════════════════════════════════════════════════════
# STEP 3: npm install
# ════════════════════════════════════════════════════════════
echo ""
log_info "STEP 3: npm install"
echo "──────────────────────────────────────────"

if ! (cd "${INSTALL_DIR}" && npm install --omit=dev --silent); then
  log_err "npm install に失敗しました。Node.js のバージョンを確認してください（v18以上推奨）"
  exit 1
fi
log_ok "npm install 完了"

# ════════════════════════════════════════════════════════════
# STEP 4: CLI シンボリックリンク作成
# ════════════════════════════════════════════════════════════
echo ""
log_info "STEP 4: CLI シンボリックリンク作成"
echo "──────────────────────────────────────────"

mkdir -p "${BIN_DIR}"
ln -sf "${INSTALL_DIR}/bin/shogun" "${BIN_DIR}/shogun"
chmod +x "${INSTALL_DIR}/bin/shogun"
log_ok "シンボリックリンクを作成しました: ${BIN_DIR}/shogun -> ${INSTALL_DIR}/bin/shogun"

# PATH に ~/.local/bin が含まれていなければ追記
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  # シェル判定
  if [[ "${SHELL}" == */zsh ]]; then
    RC_FILE="${HOME}/.zshrc"
  else
    RC_FILE="${HOME}/.bashrc"
  fi

  # 既に RC ファイルに書かれていないか確認してから追記
  PATH_LINE='export PATH="${HOME}/.local/bin:${PATH}"'
  if ! grep -qF '.local/bin' "${RC_FILE}" 2>/dev/null; then
    {
      echo ""
      echo "# Shogun CLI"
      echo "${PATH_LINE}"
    } >> "${RC_FILE}"
    log_ok "PATH を ${RC_FILE} に追加しました"
  else
    log_info "PATH への ${BIN_DIR} の追記はすでに ${RC_FILE} に存在します"
  fi
else
  log_ok "PATH に ${BIN_DIR} はすでに含まれています"
fi

# ════════════════════════════════════════════════════════════
# STEP 5: Memory MCP チェック
# ════════════════════════════════════════════════════════════
echo ""
log_info "STEP 5: Memory MCP チェック"
echo "──────────────────────────────────────────"

if command -v claude &>/dev/null && claude mcp list 2>/dev/null | grep -q memory; then
  log_ok "Memory MCP が設定されています"
else
  log_warn "Memory MCP が設定されていません（任意）。以下のコマンドで設定できます:"
  log_warn "  claude mcp add memory npx -y @modelcontextprotocol/server-memory"
fi

# ════════════════════════════════════════════════════════════
# 最終サマリー
# ════════════════════════════════════════════════════════════
echo ""
echo -e "╔══════════════════════════════════════════╗"
printf  "║  インストール完了  エラー:%-2s 警告:%-2s      ║\n" "${ERRORS}" "${WARNINGS}"
echo -e "╚══════════════════════════════════════════╝"
echo ""
echo "次のステップ:"

if [[ "${SHELL}" == */zsh ]]; then
  _RC="~/.zshrc"
else
  _RC="~/.bashrc"
fi

echo "  source ${_RC}"
echo "  cd /path/to/your/project"
echo "  shogun init"
echo "  shogun start"
echo "  shogun task \"最初の指令\""
echo ""
