`include "sys_defs.svh"

module maptable(
    input logic         clock,
    input logic         reset,
    input logic         mispredicted,
    input logic         branch_encountered,
    input X_C_PACKET    cdb [`N-1:0],
    input PRF_IDX       t_from_freelist [`N-1:0],
    input REG_IDX       dest_reg_in [`N-1:0],
    // TODO: Stored Maptable from branch stack to recover the maptable 
    output  PRF_IDX     t1 [`N-1:0],
    output  PRF_IDX     t2 [`N-1:0],
    output  PRF_IDX     told [`N-1:0]
    // TODO: An output to branch stack
);




    
endmodule