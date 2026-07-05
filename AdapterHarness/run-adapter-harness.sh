#!/usr/bin/env bash
#
# Adapter-contract gate — the contribution-alias contract.
#
# Runs OUTSIDE `swift test`: the adapter fixture package uses macros and
# depends on swift-wire, so a fixture inside swift-wire's own test targets
# would form a circular package dependency. A separate adapter + consumer
# package pair (both depending on swift-wire) exercises the contract here.
# The AdapterHarness CI job invokes this script.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== adapter contract: @RoutedBy contribution alias =="
# Builds the consumer — its WireBuildPlugin discovers the @RoutedBy definition
# from the activated WireRouting library, reads each @RoutedBy use-site as
# @Contributes(to: RoutingKeys.controllers), and collates the controllers — then
# runs it. main.swift bootstraps the generated graph and asserts the three
# controllers were collated across the package boundary, printing OK or trapping.
swift run --package-path "$DIR/Consumer"

echo "== adapter contract gate passed =="
