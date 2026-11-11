#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/ticketapp-regression.XXXXXX")"
trap 'rm -rf "$output_dir"' EXIT

# These sources use macOS-compatible Apple frameworks and no model runtime.
sources=()
while IFS= read -r source; do
    sources+=("$source")
done < <(find TicketApp/Domain TicketApp/Pipeline TicketApp/Services TicketApp/Support \
    -name '*.swift' ! -name 'ReceiptModel.swift' | sort)

failed=0
for test_main in Tests/Regression/*/main.swift; do
    suite="$(basename "$(dirname "$test_main")")"
    echo "Running $suite"
    if xcrun swiftc -module-cache-path "$output_dir/cache" \
        "${sources[@]}" "$test_main" -o "$output_dir/$suite" && "$output_dir/$suite"; then
        echo "PASS suite: $suite"
    else
        echo "FAIL suite: $suite"
        failed=1
    fi
done
exit "$failed"
