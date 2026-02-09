`include "sys_defs.svh"

module rs(
    input logic                 clock, 
    input logic                 reset, 
    input logic                 mispredicted,
    input ROB_IDX               rob_index,
    input D_S_PACKET            dispatch_pack [`N-1:0],
    input X_C_PACKET            cdb [`N-1:0],           

    output D_S_PACKET           issue_pack [`N-1:0],
    output logic [`RS_SZ-1:0]   busy_entries
    // All the packets are defined in sys_defs.svh
);












endmodule