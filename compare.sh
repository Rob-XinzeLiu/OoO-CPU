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
cd /home/xinzeliu/eecs472/pfinal_472-w26.group8

for source_file in programs/*.s programs/*c; do
    program=$(echo "$source_file" | cut -d '.' -f1 | cut -d '/' -f 2)
    
        make $program.out
        echo "Comparing writeback output for $program"
        diff correct_out/$program.wb output/$program.wb
        wb_result=$?

    if [ $wb_result -eq 0 ] 
    then
        fl_result="$program passed"
        echo_color 2 "$fl_result"
    else
        fl_result="$program failed"
        echo_color 1 "$fl_result"
    fi
done

