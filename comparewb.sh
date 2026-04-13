#!/bin/bash
echo_color() {
    # check if in a terminal and in a compliant shell
    # use tput setaf to set the ANSI Foreground color based on the number 0-7:
    # 0:black, 1:red, 2:green, 3:yellow, 4:blue, 5:magenta, 6:cyan, 7:white
    # other numbers are valid, but not specified in the man page
    if [ -t 0 ]; then tput setaf $1; fi;
    # echo the message in this color
    echo "${@:2:$#}"
    # reset the terminal color
    if [ -t 0 ]; then tput sgr0; fi
}

echo "Comparing ground truth outputs to new processor"
cd /home/xinzeliu/eecs472/optimize/pfinal_472-w26.group8

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
    #echo "Comparing memory output for $program"
    #grep '@@@' output/$program.out > mem.txt
    #grep '@@@' correct_out/$program.out > truth_mem.txt
    #diff mem.txt truth_mem.txt
    #mem_result=$?
    echo "Printing Passed or Failed"
    if [ $wb_result -eq 0 ] #&& [ $mem_result -eq 0 ]
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
        echo "" >> result.txt
    fi
done
Percentage=$(($pass*100/$total))

echo "Result"
echo_color 6 "Total tests: $total"
echo_color 2 "Passed: $pass"
echo "Percentage: $Percentage %"