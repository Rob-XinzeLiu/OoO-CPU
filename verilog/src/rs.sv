`include "sys_defs.svh"

module rs(
    input logic             clock, 
    input logic             reset, 
    input logic             mispredicted,
    input ROB_IDX           rob_index,
    input D_S_PACKET        dispatch_pack [`N-1:0],

    output D_S_PACKET       issue_pack [`N-1:0],
    // To dispatcher (how many available entries)
);












endmodule