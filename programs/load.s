addi x1, x0, 100 #0
addi x2, x0, 10  #4
sw x2, 0(x1)  #8
nop #12
nop #16
nop #20
nop # 24
nop #28
nop #32
nop # 36
nop # 40
nop # 44
nop # 48
lw   x3, 0(x1) # 52
addi x4, x3, 1 # 56
wfi # 60