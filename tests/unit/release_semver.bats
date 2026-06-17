#!/usr/bin/env bats
# Unit tests for release.sh semver validation
# Uses --dry-run: semver check runs before the branch check, so a branch error
# means the semver was accepted; a "不正なバージョン形式" error means it was rejected.

load '../test_helper'

RELEASE_SCRIPT="${SHOGUN_REPO}/.github/scripts/release.sh"

# ─── stable versions ────────────────────────────────────────

@test "release semver: accepts stable version 0.0.1" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.1
  [[ "$output" != *"不正なバージョン形式"* ]]
}

@test "release semver: accepts stable version 1.10.0" {
  run bash "${RELEASE_SCRIPT}" --dry-run 1.10.0
  [[ "$output" != *"不正なバージョン形式"* ]]
}

# ─── branch enforcement ─────────────────────────────────────
# These tests run on a feature branch, so stable versions trigger the branch check.

@test "release branch: stable version requires main branch" {
  # main ブランチからの実行時はスキップ（このテストは非 main ブランチ前提）
  [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]] || skip "on main branch"
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"stable リリースは main"* ]]
}

@test "release branch: pre-release version does not require main branch" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.19-beta.1
  [[ "$output" != *"stable リリースは main"* ]]
}

# ─── pre-release versions ───────────────────────────────────

@test "release semver: accepts beta suffix 0.0.19-beta.1" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.19-beta.1
  [[ "$output" != *"不正なバージョン形式"* ]]
}

@test "release semver: accepts alpha suffix 0.0.19-alpha.2" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.19-alpha.2
  [[ "$output" != *"不正なバージョン形式"* ]]
}

@test "release semver: accepts rc suffix 0.0.19-rc.1" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.19-rc.1
  [[ "$output" != *"不正なバージョン形式"* ]]
}

@test "release semver: accepts numeric-only suffix 1.0.0-1" {
  run bash "${RELEASE_SCRIPT}" --dry-run 1.0.0-1
  [[ "$output" != *"不正なバージョン形式"* ]]
}

# ─── invalid formats ────────────────────────────────────────

@test "release semver: rejects trailing hyphen 0.0.19-" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0.19-
  [ "$status" -ne 0 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}

@test "release semver: rejects v prefix v0.0.1" {
  run bash "${RELEASE_SCRIPT}" --dry-run v0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}

@test "release semver: rejects two-segment version 0.0" {
  run bash "${RELEASE_SCRIPT}" --dry-run 0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}

@test "release semver: rejects version with trailing space" {
  run bash "${RELEASE_SCRIPT}" --dry-run "0.0.1 "
  [ "$status" -ne 0 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}
