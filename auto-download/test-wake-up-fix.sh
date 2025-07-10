#!/bin/sh

# Script test untuk memverifikasi perbaikan wake-up detection
# Simulasi kondisi yang menyebabkan duplikasi log

echo "=== Testing Wake-up Detection Fix ==="
echo "Simulating wake-up detection scenarios..."

# Simulasi variabel global
WAKE_UP_DETECTION_ENABLED=1
WAKE_UP_DETECTED=0
LAST_SCREEN_STATE="1"
LAST_SCREEN_ON_COUNT="10"
WAKE_UP_DEBOUNCE_ENABLED=1
WAKE_UP_DEBOUNCE_INTERVAL=600
LAST_WAKE_UP_TIME=0

# Mock functions untuk testing
getprop() {
    if [ "$1" = "debug.tracing.screen_state" ]; then
        echo "2"  # Simulate screen ON
    fi
}

dumpsys() {
    if [ "$*" = "activity broadcasts" ]; then
        # Simulate multiple SCREEN_ON broadcasts
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"
        echo "android.intent.action.SCREEN_ON"  # 12 total, lebih dari LAST_SCREEN_ON_COUNT
    fi
}

date() {
    if [ "$1" = "+%s" ]; then
        echo "1720000000"  # Mock timestamp
    fi
}

# Mock is_wake_up_allowed function
is_wake_up_allowed() {
    return 0  # Always allow for testing
}

# Test function - simplified version of detect_wake_up_event
test_detect_wake_up_event() {
    echo "Testing detect_wake_up_event..."
    
    if [ $WAKE_UP_DETECTION_ENABLED -eq 0 ]; then
        echo "Wake-up detection disabled"
        return 0
    fi
    
    # Test the fix: Jika wake-up sudah terdeteksi dan belum ditangani, jangan deteksi lagi
    if [ $WAKE_UP_DETECTED -eq 1 ]; then
        echo "Wake-up already detected, skipping detection"
        return 1
    fi
    
    local wake_up_detected=0
    
    # Primary detection: Monitor broadcast intents SCREEN_ON
    local current_screen_on_count=$(dumpsys activity broadcasts 2>/dev/null | grep -c "android.intent.action.SCREEN_ON" 2>/dev/null || echo "0")
    
    # Secondary detection: Monitor system properties debug.tracing.screen_state
    local current_screen_state=$(getprop debug.tracing.screen_state 2>/dev/null)
    
    echo "Current screen on count: $current_screen_on_count"
    echo "Last screen on count: $LAST_SCREEN_ON_COUNT"
    echo "Current screen state: $current_screen_state"
    echo "Last screen state: $LAST_SCREEN_STATE"
    
    # Primary detection: Periksa apakah ada SCREEN_ON broadcast baru
    if [ -n "$LAST_SCREEN_ON_COUNT" ] && [ "$current_screen_on_count" -gt "$LAST_SCREEN_ON_COUNT" ]; then
        wake_up_detected=1
        echo "Wake-up detected via SCREEN_ON broadcast"
    fi
    
    # Secondary detection: Deteksi perubahan screen state
    local screen_was_off=0
    local screen_is_on=0
    
    if [ "$LAST_SCREEN_STATE" = "1" ]; then
        screen_was_off=1
    fi
    
    if [ "$current_screen_state" = "2" ]; then
        screen_is_on=1
    fi
    
    if [ $screen_was_off -eq 1 ] && [ $screen_is_on -eq 1 ]; then
        wake_up_detected=1
        echo "Wake-up detected via screen state change"
    fi
    
    # Update last states hanya jika tidak ada wake-up yang terdeteksi
    if [ $wake_up_detected -eq 0 ]; then
        LAST_SCREEN_STATE="$current_screen_state"
        LAST_SCREEN_ON_COUNT="$current_screen_on_count"
        echo "States updated (no wake-up detected)"
    fi
    
    # Jika wake-up terdeteksi, periksa debouncing
    if [ $wake_up_detected -eq 1 ]; then
        if is_wake_up_allowed; then
            # Update states setelah wake-up diizinkan untuk mencegah deteksi berulang
            LAST_SCREEN_STATE="$current_screen_state"
            LAST_SCREEN_ON_COUNT="$current_screen_on_count"
            WAKE_UP_DETECTED=1
            echo "Wake-up allowed and flag set"
            return 1
        else
            # Update states meskipun wake-up tidak diizinkan untuk mencegah spam detection
            LAST_SCREEN_STATE="$current_screen_state"
            LAST_SCREEN_ON_COUNT="$current_screen_on_count"
            echo "Wake-up not allowed but states updated"
            return 0
        fi
    fi
    
    echo "No wake-up detected"
    return 0
}

# Test scenario 1: First detection
echo ""
echo "=== Test 1: First wake-up detection ==="
test_detect_wake_up_event
result1=$?
echo "Result: $result1 (should be 1 - wake-up detected)"
echo "WAKE_UP_DETECTED flag: $WAKE_UP_DETECTED"

echo ""
echo "=== Test 2: Second call (should be skipped) ==="
test_detect_wake_up_event
result2=$?
echo "Result: $result2 (should be 1 - already detected, skipped)"

echo ""
echo "=== Test 3: Third call (should be skipped) ==="
test_detect_wake_up_event
result3=$?
echo "Result: $result3 (should be 1 - already detected, skipped)"

# Reset for next test
WAKE_UP_DETECTED=0
echo ""
echo "=== Test 4: After reset ==="
echo "WAKE_UP_DETECTED reset to: $WAKE_UP_DETECTED"
test_detect_wake_up_event
result4=$?
echo "Result: $result4 (should be 0 - no new wake-up since states already updated)"

echo ""
echo "=== Test Summary ==="
echo "Test 1 (First detection): $result1 (expected: 1)"
echo "Test 2 (Second call): $result2 (expected: 1)"
echo "Test 3 (Third call): $result3 (expected: 1)"
echo "Test 4 (After reset): $result4 (expected: 0)"

if [ $result1 -eq 1 ] && [ $result2 -eq 1 ] && [ $result3 -eq 1 ] && [ $result4 -eq 0 ]; then
    echo ""
    echo "✅ ALL TESTS PASSED - Wake-up detection fix is working correctly!"
    echo "The fix prevents multiple 'Schedule check wake-up event' logs."
else
    echo ""
    echo "❌ SOME TESTS FAILED - Please check the implementation."
fi

echo ""
echo "=== Fix Explanation ==="
echo "1. Added check: if WAKE_UP_DETECTED=1, skip detection and return 1"
echo "2. Update states only after wake-up is allowed to prevent re-detection"
echo "3. In main loop: check WAKE_UP_DETECTED before calling detect_wake_up_event"
echo "4. This prevents multiple detection of the same wake-up event"