#!/bin/bash
echo_color() {
    if [ -t 0 ]; then tput setaf $1; fi;
    echo "${@:2:$#}"
    if [ -t 0 ]; then tput sgr0; fi
}
echo "Comparing ground truth outputs to new processor"
cd /home/xinzeliu/eecs472/pfinal_472-w26.group8
total=0
pass=0
> result.txt
for source_file in programs/*.s programs/*c; do
    if [ "$source_file" = "programs/crt.s" ]
    then
        continue
    fi
    ((total++))
    program=$(echo "$source_file" | cut -d '.' -f1 | cut -d '/' -f 2)
    echo "Running $program"
    make $program.out
    echo "Comparing writeback output for $program"
    diff correct_out/$program.wb output/$program.wb
    wb_result=$?
    echo "Printing Passed or Failed"
    if [ $wb_result -eq 0 ]
    then 
        ((pass++))
        fl_result="$program passed"
        echo_color 2 "$fl_result"
        echo "$fl_result" >> result.txt
        echo "" >> result.txt
    else
        fl_result="$program failed"
        echo_color 1 "$fl_result"
        echo "$fl_result" >> result.txt
        first_line=$(diff correct_out/$program.wb output/$program.wb | grep "^[0-9]" | head -1)
        first_diff=$(diff correct_out/$program.wb output/$program.wb | grep "^[<>]" | head -2)
        echo "First difference at line: $first_line" >> result.txt
        echo "$first_diff" >> result.txt
        echo "" >> result.txt
    fi
done
Percentage=$(($pass*100/$total))
echo "Result"
echo_color 6 "Total tests: $total"
echo_color 2 "Passed: $pass"
echo "Percentage: $Percentage %"