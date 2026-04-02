_start: jal  x1, func_a     # PC 0x00, ra = 0x04
        jal  x1, func_b     # PC 0x04, ra = 0x08
        jal  x0, finsih     # PC 0x08
func_a: jalr x0, x1, 0     # PC 0x10, ret to 0x04
func_b: jalr x0, x1, 0     # PC 0x14, ret to 0x08
finsih: wfi