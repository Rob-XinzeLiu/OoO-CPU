`include "sys_defs.svh"

typedef struct packed {
    ADDR    pc;
    logic   valid;
    logic [`TAG_CNT-1:0] t;
    logic [`TAG_CNT-1:0] told;
    logic ready_retire;//how many inst can we retire per cycle?
    logic [$clog2(`ROB_SZ)-1:0] index;
    logic [2:0] func_type;// TBD
    REG_IDX  dest_reg_idx; 
} ROB_ENTRY;