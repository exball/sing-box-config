#!/bin/sh

# Test script untuk smart_sleep implementation
# Script ini untuk testing apakah smart_sleep berfungsi dengan baik

echo "=== Smart Sleep Test Script ==="
echo "Testing smart_sleep functionality..."

# Source fungsi smart_sleep dari auto-download.sh
SCRIPT_DIR="$(dirname "$0")"
AUTO_DOWNLOAD_SCRIPT="$SCRIPT_DIR/auto-download.sh"

if [ ! -f "$AUTO_DOWNLOAD_SCRIPT" ]; then
    echo "Error: auto-download.sh not found at $AUTO_DOWNLOAD_SCRIPT"
    exit 1
fi

# Extract smart_sleep function (simplified test)
smart_sleep_test() {
    local sleep_duration="$1"
    local elapsed=0
    local check_interval=5  # Shorter interval for testing
    
    echo "Starting smart_sleep test for $sleep_duration seconds..."
    
    # Setup signal handler
    trap 'wake_interrupted=true; echo "Signal received!"' USR1
    wake_interrupted=false
    
    # Sleep loop
    while [ $elapsed -lt $sleep_duration ] && [ "$wake_interrupted" = "false" ]; do
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        echo "Elapsed: ${elapsed}s / ${sleep_duration}s"
    done
    
    # Reset trap
    trap - USR1
    
    if [ "$wake_interrupted" = "true" ]; then
        echo "Smart sleep interrupted by signal (slept ${elapsed}s of ${sleep_duration}s)"
        return 1
    else
        echo "Smart sleep completed normally (${sleep_duration}s)"
        return 0
    fi
}

# Test 1: Normal sleep completion
echo ""
echo "Test 1: Normal sleep completion (10 seconds)"
smart_sleep_test 10
echo "Test 1 result: $?"

# Test 2: Signal interruption test
echo ""
echo "Test 2: Signal interruption test (30 seconds)"
echo "Send 'kill -USR1 $$' from another terminal to test interruption"
echo "PID for testing: $$"

smart_sleep_test 30
echo "Test 2 result: $?"

echo ""
echo "=== Test completed ==="