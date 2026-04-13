#!/bin/bash
echo_color() {
    if [ -t 0 ]; then tput setaf $1; fi;
    echo "${@:2:$#}"
    if [ -t 0 ]; then tput sgr0; fi
}

echo "Computing CPI/IPC/TPI for each program"
> result.txt

CLOCK_PERIOD=$(grep 'CLOCK_PERIOD' Makefile | awk '{print $3}')
echo "Clock period: ${CLOCK_PERIOD} ns"
echo "Clock period: ${CLOCK_PERIOD} ns" >> result.txt
echo "" >> result.txt

printf "%-20s %10s %10s %10s %10s %10s %14s\n" "Program" "Cycles" "Instrs" "CPI" "IPC" "Time(ns)" "TPI(ns/inst)" >> result.txt
printf "%-20s %10s %10s %10s %10s %10s %14s\n" "-------" "------" "------" "---" "---" "--------" "------------" >> result.txt

total_cpi=0
total_ipc=0
total_tpi=0
count=0

for source_file in programs/*.s programs/*.c; do
    [ -f "$source_file" ] || continue
    program=$(basename "$source_file" | cut -d '.' -f1)
    echo "Running $program"

    make output/$program.out
    if [ $? -ne 0 ]; then
        echo_color 1 "$program: simulation failed"
        printf "%-20s %10s\n" "$program" "FAILED" >> result.txt
        continue
    fi

    cpi_file="output/$program.cpi"
    if [ ! -f "$cpi_file" ]; then
        echo_color 1 "$program: no .cpi file found"
        printf "%-20s %10s\n" "$program" "NO_CPI" >> result.txt
        continue
    fi

    cycles=$(grep 'cycles' "$cpi_file" | awk '{print $2}')
    instrs=$(grep 'cycles' "$cpi_file" | awk '{print $5}')
    cpi=$(grep 'cycles' "$cpi_file" | awk '{print $8}')
    time_ns=$(grep 'ns total' "$cpi_file" | awk '{print $2}')

    ipc=$(awk "BEGIN {printf \"%.6f\", 1.0 / $cpi}")
    tpi=$(awk "BEGIN {printf \"%.6f\", $time_ns / $instrs}")

    echo_color 2 "$program:"
    echo "  Cycles:  $cycles"
    echo "  Instrs:  $instrs"
    echo "  CPI:     $cpi"
    echo "  IPC:     $ipc"
    echo "  Time:    ${time_ns} ns"
    echo "  TPI:     ${tpi} ns/instr"

    printf "%-20s %10s %10s %10s %10s %10s %14s\n" "$program" "$cycles" "$instrs" "$cpi" "$ipc" "$time_ns" "$tpi" >> result.txt

    total_cpi=$(awk "BEGIN {printf \"%.6f\", $total_cpi + $cpi}")
    total_ipc=$(awk "BEGIN {printf \"%.6f\", $total_ipc + $ipc}")
    total_tpi=$(awk "BEGIN {printf \"%.6f\", $total_tpi + $tpi}")
    count=$((count + 1))
done

if [ $count -gt 0 ]; then
    avg_cpi=$(awk "BEGIN {printf \"%.6f\", $total_cpi / $count}")
    avg_ipc=$(awk "BEGIN {printf \"%.6f\", $total_ipc / $count}")
    avg_tpi=$(awk "BEGIN {printf \"%.6f\", $total_tpi / $count}")

    echo ""
    echo_color 6 "Average over $count programs:"
    echo "  Avg CPI: $avg_cpi"
    echo "  Avg IPC: $avg_ipc"
    echo "  Avg TPI: $avg_tpi ns/instr"

    printf "%-20s %10s %10s %10s %10s %10s %14s\n" "-------" "------" "------" "---" "---" "--------" "------------" >> result.txt
    printf "%-20s %10s %10s %10s %10s %10s %14s\n" "AVERAGE($count)" "" "" "$avg_cpi" "$avg_ipc" "" "$avg_tpi" >> result.txt
fi

echo ""
echo_color 6 "Results saved to result.txt"