#!/usr/bin/env bats
# Unit tests for shogun upgrade option parsing and _semver_lt

load '../test_helper'

setup() {
  # bin/shogun を source して実際の _semver_lt を使う
  # BASH_SOURCE ガードにより末尾のディスパッチャはスキップされる
  # shellcheck disable=SC1090
  source "${SHOGUN_REPO}/bin/shogun"
}

# ─── _semver_lt ───────────────────────────────────────────

@test "_semver_lt: patch increment returns true" {
  _semver_lt v0.0.1 v0.0.2
}

@test "_semver_lt: minor increment returns true" {
  _semver_lt v0.0.9 v0.1.0
}

@test "_semver_lt: major increment returns true" {
  _semver_lt v0.9.9 v1.0.0
}

@test "_semver_lt: large minor numbers compared correctly (no lexicographic)" {
  _semver_lt v1.9.0 v1.10.0
}

@test "_semver_lt: equal versions returns false" {
  run _semver_lt v1.0.0 v1.0.0
  [ "$status" -eq 1 ]
}

@test "_semver_lt: greater version returns false" {
  run _semver_lt v0.0.2 v0.0.1
  [ "$status" -eq 1 ]
}

@test "_semver_lt: works without v prefix" {
  _semver_lt 0.0.1 0.0.2
}

# ─── cmd_upgrade option parsing ───────────────────────────

@test "upgrade: rejects unknown option" {
  run shogun upgrade --unknown-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"不明なオプション"* ]]
}

@test "upgrade: rejects empty --version= value" {
  run shogun upgrade --version=
  [ "$status" -eq 1 ]
  [[ "$output" == *"--version"* ]]
}

@test "upgrade: rejects invalid version format (missing v prefix)" {
  run shogun upgrade --version 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}

@test "upgrade: rejects invalid version format (= form, missing v prefix)" {
  run shogun upgrade --version=1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}

@test "upgrade: accepts pre-release version v0.1.0-beta.1" {
  run shogun upgrade --version v0.1.0-beta.1
  [[ "$output" != *"不正なバージョン形式"* ]]
}

@test "upgrade: accepts pre-release version v1.0.0-rc.1" {
  run shogun upgrade --version v1.0.0-rc.1
  [[ "$output" != *"不正なバージョン形式"* ]]
}

@test "upgrade: rejects pre-release with trailing hyphen v0.1.0-" {
  run shogun upgrade --version v0.1.0-
  [ "$status" -eq 1 ]
  [[ "$output" == *"不正なバージョン形式"* ]]
}
