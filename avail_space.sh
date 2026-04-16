#!/bin/bash

echo_color() {
    if [ -t 1 ]; then tput setaf $1; fi
    echo "${@:2:$#}"
    if [ -t 1 ]; then tput sgr0; fi
}

# ---------------------------------------------------------------
# Signals to track (must match exactly what tb prints)
# ---------------------------------------------------------------
SIGNALS=(
    "can_fetch_num"
    "dispatch_num"
    "rob_space_avail"
    "rs_empty_entries_num"
    "freelist_avail_num"
    "branch_stack_space_avail"
    "branch_avail_num"
    "lq_space_available"
    "sq_space_available"
)

RESULT_FILE="avail_result.txt"
> "$RESULT_FILE"

echo "Computing availability stats for each program"
echo ""

# Correct way to parse CLOCK_PERIOD from this Makefile
CLOCK_PERIOD=$(grep 'export CLOCK_PERIOD' Makefile | awk -F'=' '{print $2}' | tr -d ' ')
echo "Clock period: ${CLOCK_PERIOD} ns"
echo "Clock period: ${CLOCK_PERIOD} ns" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

# Accumulators keyed by signal name
declare -A sum0 sum1 sum2
for sig in "${SIGNALS[@]}"; do
    sum0[$sig]="0"
    sum1[$sig]="0"
    sum2[$sig]="0"
done
count=0
failed=0

# ---------------------------------------------------------------
# Main loop over programs (same logic as your existing script)
# ---------------------------------------------------------------
for source_file in programs/*.s programs/*.c; do
    [ -f "$source_file" ] || continue
    # skip crt.s
    basename_file=$(basename "$source_file")
    [ "$basename_file" = "crt.s" ] && continue

    program=$(basename "$source_file" | cut -d '.' -f1)
    echo "Running $program"

    # Use same make target as your Makefile: output/$program.out
    make output/$program.out > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo_color 1 "  $program: simulation failed, skipping"
        failed=$((failed + 1))
        continue
    fi

    log_file="output/$program.log"
    if [ ! -f "$log_file" ]; then
        echo_color 1 "  $program: output/$program.log not found, skipping"
        failed=$((failed + 1))
        continue
    fi

    if ! grep -q "Availability Stats" "$log_file"; then
        echo_color 1 "  $program: no availability stats block in log, skipping"
        failed=$((failed + 1))
        continue
    fi

    # Parse each signal
    all_ok=1
    for sig in "${SIGNALS[@]}"; do
        # grep the line that starts with the signal name (anchored)
        line=$(grep "^${sig} " "$log_file" | tail -1)
        if [ -z "$line" ]; then
            echo_color 1 "  $program: signal '$sig' not found in log"
            all_ok=0
            break
        fi
        v0=$(echo "$line" | awk '{print $2}')
        v1=$(echo "$line" | awk '{print $3}')
        v2=$(echo "$line" | awk '{print $4}')
        sum0[$sig]=$(awk "BEGIN {printf \"%.6f\", ${sum0[$sig]} + $v0}")
        sum1[$sig]=$(awk "BEGIN {printf \"%.6f\", ${sum1[$sig]} + $v1}")
        sum2[$sig]=$(awk "BEGIN {printf \"%.6f\", ${sum2[$sig]} + $v2}")
    done

    if [ $all_ok -eq 1 ]; then
        echo_color 2 "  $program: OK"
        count=$((count + 1))
    else
        failed=$((failed + 1))
    fi
done

# ---------------------------------------------------------------
# Print averages
# ---------------------------------------------------------------
echo ""
if [ $count -eq 0 ]; then
    echo_color 1 "No programs produced valid stats."
    exit 1
fi

FMT="%-28s  %8s  %8s  %8s\n"

echo_color 6 "========= Average Availability Stats over $count programs ($failed failed) ========="
printf "$FMT" "Signal" "==0 %" "==1 %" ">=2 %"
printf "$FMT" "----------------------------" "--------" "--------" "--------"

{
    echo ""
    printf "Average Availability Stats over $count programs ($failed failed):\n"
    printf "$FMT" "Signal" "==0 %" "==1 %" ">=2 %"
    printf "$FMT" "----------------------------" "--------" "--------" "--------"
} >> "$RESULT_FILE"

for sig in "${SIGNALS[@]}"; do
    avg0=$(awk "BEGIN {printf \"%.2f\", ${sum0[$sig]} / $count}")
    avg1=$(awk "BEGIN {printf \"%.2f\", ${sum1[$sig]} / $count}")
    avg2=$(awk "BEGIN {printf \"%.2f\", ${sum2[$sig]} / $count}")
    printf "$FMT" "$sig" "$avg0" "$avg1" "$avg2"
    printf "$FMT" "$sig" "$avg0" "$avg1" "$avg2" >> "$RESULT_FILE"
done

echo ""
echo_color 6 "Results saved to $RESULT_FILE"