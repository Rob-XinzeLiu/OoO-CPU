addi x1, x0, 100 #0
addi x2, x0, 10  #4
sw x2, 0(x1)  #8
lw  x3, 0(x1) #12
nop #16
nop #20
nop #24
nop # 28
nop #32
nop #36
nop # 40
nop # 44
nop # 48
nop # 52
lw   x4, 0(x1) # 56
lw   x5, 0(x1) # 60
lw   x6, 0(x1) # 64
lw   x7, 0(x1) # 68
wfi # 72