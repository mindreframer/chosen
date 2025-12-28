#!/usr/bin/env bash
set -e

echo "================================"
echo "Running QA Checks"
echo "================================"
echo ""

# Format code
echo "→ Formatting code..."
mix format
echo "✓ Code formatted"
echo ""

# Run tests
echo "→ Running tests..."
mix test
echo "✓ Tests passed"
echo ""

# Run dialyzer (if available)
echo "→ Running Dialyzer..."
if mix help dialyzer &> /dev/null; then
  mix dialyzer
  echo "✓ Dialyzer passed"
else
  echo "⚠ Dialyzer not available (add {:dialyxir, \"~> 1.4\", only: :dev, runtime: false} to deps)"
fi
echo ""

echo "================================"
echo "✓ All QA checks passed!"
echo "================================"
