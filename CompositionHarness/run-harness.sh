#!/usr/bin/env bash
#
# Iteration-7g multi-module composition gate.
#
# This runs OUTSIDE `swift test`: the harness library uses Wire's macros,
# so it depends on swift-wire — and a fixture package that swift-wire's own
# test targets depended on would form a circular package dependency. So the
# external-`.product` activation path is exercised by a separate
# consumer+library package pair that depend on swift-wire (one direction),
# run here. The CompositionHarness CI job invokes this script.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== 7g positive: external-package composition =="
# Builds the consumer (its WireBuildPlugin re-parses and composes the
# external WireHarnessLibrary), then runs it — main.swift bootstraps the
# generated graph and asserts the library's unkeyed + keyed bindings
# composed across the package boundary, printing OK or trapping.
swift run --package-path "$DIR/Consumer"

echo "== 7g gate passed =="
