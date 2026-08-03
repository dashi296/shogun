#!/usr/bin/env bats
# Integration tests for `shogun doctor` の agmsg セクション

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
  export AGMSG_TEST_HOME="$(mktemp -d)"
  export AGMSG_HOME_OVERRIDE="${AGMSG_TEST_HOME}"
}

teardown() {
  rm -rf "${AGMSG_TEST_HOME}"
  teardown_test_project
}

@test "doctor: reports agmsg as missing when not installed" {
  run shogun doctor
  [[ "$output" == *"agmsg が見つかりません"* ]]
}

@test "doctor: reports agmsg version when installed and matching" {
  mkdir -p "${AGMSG_TEST_HOME}/scripts"
  echo "v1.1.12-3-g1c7efbc" > "${AGMSG_TEST_HOME}/VERSION"
  run shogun doctor
  [[ "$output" == *"v1.1.12-3-g1c7efbc"* ]]
}

@test "doctor: warns when agmsg version does not match the expected series" {
  mkdir -p "${AGMSG_TEST_HOME}/scripts"
  echo "v2.0.0" > "${AGMSG_TEST_HOME}/VERSION"
  run shogun doctor
  [[ "$output" == *"想定外"* ]]
}

@test "doctor: warns (does not abort) when agmsg.cmd_name is invalid" {
  node_yaml() {
    NODE_PATH="${SHOGUN_REPO}/node_modules" node "$@"
  }
  node_yaml -e '
const fs = require("fs");
const yaml = require("js-yaml");
const file = ".shogun/config.yaml";
const d = yaml.load(fs.readFileSync(file, "utf8")) || {};
d.agmsg = d.agmsg || {};
d.agmsg.cmd_name = "bad name";
fs.writeFileSync(file, yaml.dump(d, {allowUnicode: true}));
'
  run shogun doctor
  [[ "$output" == *"agmsg.cmd_name が不正です"* ]]
  [[ "$output" == *"[ .shogun/ ]"* ]]
}
