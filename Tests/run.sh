#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/moyu-regression.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
SOURCES=(App/CategoryRules.swift App/DesignSystem.swift App/MonthlyUsage.swift App/AquariumModel.swift App/FishBrain.swift App/DomainRules.swift App/WebsiteDomain.swift App/WebGroup.swift App/VideoPageRules.swift App/Store.swift
         App/BrowserURLReader.swift App/FirefoxURLReader.swift App/BrowserAuthorizationModel.swift App/IdleClock.swift App/PassiveSignal.swift App/UsageTracker.swift App/StatsViewModel.swift)
export MOYU_PUBLIC_SUFFIX_LIST="$PWD/App/Resources/public_suffix_list.dat"
for TEST in TimingRegression InteractionRegression BrowserAuthorizationRegression BrowserSupportRegression FirefoxRegression BrowserExclusivityRegression MainDomainRegression AppearanceRegression MonthlyUsageRegression AquariumRegression; do
  swiftc -O "${SOURCES[@]}" "Tests/$TEST.swift" \
    -framework Cocoa -framework ApplicationServices -framework SwiftUI -framework IOKit -framework CoreAudio -lsqlite3 -o "$TEST_BUILD_DIR/$TEST"
  "$TEST_BUILD_DIR/$TEST"
done
