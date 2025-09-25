#!/usr/bin/env bash
# Quick test script to debug matrix variables

echo "=== Matrix Variable Debug ==="
echo "All environment variables:"
env | sort

echo ""
echo "Matrix-related variables:"
env | grep -i matrix

echo ""
echo "Buildkite variables:"
env | grep ^BUILDKITE

echo ""
echo "Expected matrix variable:"
echo "BUILDKITE_MATRIX_SETUP_INTEGRATION = ${BUILDKITE_MATRIX_SETUP_INTEGRATION:-<NOT SET>}"