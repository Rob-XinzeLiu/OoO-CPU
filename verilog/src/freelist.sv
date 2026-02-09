`include "sys_defs.svh"

module freelist{
    input logic         clock,
    input logic         reset,
    input PRF_IDX       told_from_rob [`N-1:0],
    input logic [1:0]   num_tag_requested,
    // TODO: is_branch as an input to take snapshots 


    output PRF_IDX      t [`N-1:0],
    output logic        full
    // TODO: Sent head_ptr to the branch stack
};







endmodule