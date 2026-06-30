#!/usr/bin/env bash
#
# Iteration-8 adapter-contract gate.
#
# Runs OUTSIDE `swift test`: the adapter fixture package uses macros and
# depends on swift-wire, so a fixture inside swift-wire's own test targets
# would form a circular package dependency. A separate adapter + consumer
# package pair (both depending on swift-wire) exercises the contract here.
# The AdapterHarness CI job invokes this script.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== iteration 8 positive: @RoutedBy adapter registration =="
# Builds the consumer — its WireBuildPlugin discovers the @RoutedBy definition
# from the activated WireRouting library, validates the registration's
# dependencies against the graph, and emits the _wireRegister call — then runs
# it. main.swift bootstraps the generated graph and asserts the controller was
# registered with the router, printing OK or trapping.
swift run --package-path "$DIR/Consumer"

echo "== iteration 8 gate passed =="
