    addi x1, x0, 1      # add 1 to x1
    addi x2, x0, 2
    addi x3, x0, 2
    mul  x7, x2, x3
    beq  x2, x3, L4
    addi x4, x0, 4
    ori x5, x0, 5
    nop
    nop
L4: add x3, x1, x2
    wfi
