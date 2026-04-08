
`include "sys_defs.svh"
`include "ISA.svh"
module btb (
    input clock,
    input reset,

    // Lookup
    input ADDR      lookup_pc,
    output logic    btb_hit,
    output ADDR     btb_target,
    output CTYPE    btb_c_type,
    output logic    btb_slot,
    
    // Update from execute, for cond branch and jalr
    input logic     update_valid,   // Is this really a branch
    input logic     update_taken,   // Did it take the branch.
    input ADDR      update_pc,
    input ADDR      update_target,
    input CTYPE     update_c_type,
    //update from dispatch, for jal
    input logic     early_update_valid,
    input ADDR      early_update_pc,
    input ADDR      early_update_target,
    input CTYPE     early_update_c_type
);
    localparam SETS = 16;
    localparam ADDR_WIDTH = 32;
    localparam BYTE_OFFSET = $clog2(8); // 2 insts
    localparam INDEX_BITS = $clog2(SETS);
    localparam TAG_BITS = ADDR_WIDTH - INDEX_BITS - BYTE_OFFSET;

    typedef struct packed{
        logic [TAG_BITS-1:0]    tag;
        // slot 0
        logic                   valid0;
        logic [ADDR_WIDTH-1:0]  target0;
        CTYPE                   c_type0;
        // slot 1
        logic                   valid1;
        logic [ADDR_WIDTH-1:0]  target1;
        CTYPE                   c_type1;
    } btb_entry;

    btb_entry btb_table [SETS];

    // Read index and tag
    logic [TAG_BITS-1:0]    rd_tag;
    logic [INDEX_BITS-1:0]  rd_index;
    
    assign rd_tag = lookup_pc[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    assign rd_index = lookup_pc[BYTE_OFFSET+INDEX_BITS-1 : BYTE_OFFSET];

    // Lookup
    logic [1:0]                     btb_hit_c;
    logic tag_match;

    assign tag_match = (btb_table[rd_index].tag == rd_tag);

    always_comb begin
        btb_hit = 1'b0;
        btb_target = '0;
        btb_c_type = C_NONE;
        btb_slot = 1'b0;
        btb_hit_c[0] = tag_match && btb_table[rd_index].valid0 && (lookup_pc[2] == 1'b0);    // Only in this situation that we can say slot 0 is hit.
        btb_hit_c[1] = tag_match && btb_table[rd_index].valid1;

        if(btb_hit_c[0]) begin
            btb_hit = 1'b1;
            btb_target = btb_table[rd_index].target0;
            btb_c_type = btb_table[rd_index].c_type0;
            btb_slot = 1'b0;
        end else if(btb_hit_c[1]) begin
            btb_hit = 1'b1;
            btb_target = btb_table[rd_index].target1;
            btb_c_type = btb_table[rd_index].c_type1;
            btb_slot = 1'b1;
        end else begin
            btb_hit = 1'b0;
        end
    end

    // Update
    logic [TAG_BITS-1:0]            wr_tag;
    logic [INDEX_BITS-1:0]          wr_index;
    
    assign wr_tag = update_pc[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    assign wr_index = update_pc[BYTE_OFFSET+INDEX_BITS-1 : BYTE_OFFSET];

    logic [TAG_BITS-1:0]   early_wr_tag;
    logic [INDEX_BITS-1:0] early_wr_index;

    assign early_wr_tag   = early_update_pc[ADDR_WIDTH-1 : ADDR_WIDTH-TAG_BITS];
    assign early_wr_index = early_update_pc[BYTE_OFFSET+INDEX_BITS-1 : BYTE_OFFSET];


    always_ff @(posedge clock) begin
        if(reset) begin
            btb_table <= '{default: '0};
        end else begin

            if (early_update_valid) begin
                if (btb_table[early_wr_index].tag != early_wr_tag) begin
                    btb_table[early_wr_index].valid0 <= 1'b0;
                    btb_table[early_wr_index].valid1 <= 1'b0;
                end
                btb_table[early_wr_index].tag <= early_wr_tag;
                if (early_update_pc[2] == 0) begin
                    btb_table[early_wr_index].valid0   <= 1'b1;
                    btb_table[early_wr_index].target0  <= early_update_target;
                    btb_table[early_wr_index].c_type0  <= early_update_c_type;
                end else begin
                    btb_table[early_wr_index].valid1   <= 1'b1;
                    btb_table[early_wr_index].target1  <= early_update_target;
                    btb_table[early_wr_index].c_type1  <= early_update_c_type;
                end
            end
            
            if(update_valid) begin
                if(update_taken) begin
                    if(btb_table[wr_index].tag != wr_tag) begin
                        btb_table[wr_index].valid0 <= 1'b0;
                        btb_table[wr_index].valid1 <= 1'b0;
                    end
                    btb_table[wr_index].tag <= wr_tag;
                    if(update_pc[2] == 0) begin
                        btb_table[wr_index].valid0 <= 1'b1;
                        btb_table[wr_index].target0 <= update_target;
                        btb_table[wr_index].c_type0 <= update_c_type;
                    end else begin
                        btb_table[wr_index].valid1 <= 1'b1;
                        btb_table[wr_index].target1 <= update_target;
                        btb_table[wr_index].c_type1 <= update_c_type;
                    end
                end else begin          // Predict taken but actually not-taken
                    if(btb_table[wr_index].tag == wr_tag) begin
                        if(update_pc[2] == 0 && btb_table[wr_index].valid0) 
                            btb_table[wr_index].valid0 <= 1'b0;
                        else if(update_pc[2] == 1 && btb_table[wr_index].valid1)    
                            btb_table[wr_index].valid1 <= 1'b0;
                    end
                end
            end
        end
    end


endmodule