        addi x5, x0, 2      
        addi x2, x0, 10     
Loop:   addi x5, x5, -1     
        jal  x1, Target    
Back:   bne  x5, x0, Loop   
        wfi                 
Target: addi x2, x2, 1     
        jal  x0, Back      