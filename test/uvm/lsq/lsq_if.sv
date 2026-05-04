// lsq_if.sv - UVM interface for the split load/store queue testbench.
`ifndef LSQ_IF_SV
`define LSQ_IF_SV
`include "sys_defs.svh"

interface lsq_if(input logic clk);

    logic                 reset;

    // Dispatch inputs shared by LQ/SQ.
    logic [31:0]          inst_in_bits         [`N-1:0];
    logic [`N-1:0]        is_load;
    logic [`N-1:0]        is_store;
    logic [`N-1:0]        is_branch;
    logic [$bits(PRF_IDX)-1:0] dest_tag_in_bits[`N-1:0];
    ROB_IDX               rob_index            [`N-1:0];

    // Execute / retire inputs.
    LQ_PACKET             load_execute_pack;
    SQ_PACKET             store_execute_pack;
    SQ_PACKET             store_retire_pack    [`N-1:0];
    logic                 load_retire_valid;
    logic [1:0]           load_retire_num;

    // Recovery.
    logic                 mispredicted;
    LQ_IDX                BS_lq_tail_in;
    SQ_IDX                BS_sq_tail_in;

    // Cache-model side.
    logic                 dcache_can_accept_store;
    logic                 dcache_can_accept_load;
    dcache_data_t         dcache_load_packet;

    // SQ outputs and LQ forwarding inputs.
    SQ_PACKET             sq_out;
    SQ_IDX                BS_sq_tail_out        [`N-1:0];
    logic [1:0]           sq_space_available;
    logic [`SQ_SZ-1:0]    sq_addr_ready_mask;
    SQ_IDX                sq_index             [`N-1:0];
    SQ_IDX                sq_head_out;
    ADDR                  sq_addr_out          [`SQ_SZ-1:0];
    logic                 sq_addr_ready_out    [`SQ_SZ-1:0];
    DATA                  sq_data_out          [`SQ_SZ-1:0];
    logic                 sq_data_ready_out    [`SQ_SZ-1:0];
    logic [2:0]           sq_funct3_out        [`SQ_SZ-1:0];
    logic [`SQ_SZ-1:0]    sq_valid_out;
    logic [`SQ_SZ-1:0]    sq_valid_out_mask    [`N-1:0];
    SQ_IDX                sq_tail_out          [`N-1:0];

    // LQ outputs.
    LQ_IDX                lq_index             [`N-1:0];
    LQ_IDX                BS_lq_tail_out       [`N-1:0];
    logic [1:0]           lq_space_available;
    LQ_PACKET             load_packet;
    logic                 cdb_req_load;
    LQ_PACKET             lq_out;

    clocking drv_cb @(negedge clk);
        output reset;
        output inst_in_bits, is_load, is_store, is_branch, dest_tag_in_bits, rob_index;
        output load_execute_pack, store_execute_pack, store_retire_pack;
        output load_retire_valid, load_retire_num;
        output mispredicted, BS_lq_tail_in, BS_sq_tail_in;
        output dcache_can_accept_store, dcache_can_accept_load, dcache_load_packet;
        input  sq_index, lq_index, sq_tail_out, sq_valid_out_mask;
        input  load_packet, sq_out, cdb_req_load, lq_out;
        input  sq_valid_out, sq_addr_ready_out, sq_data_ready_out, sq_addr_out, sq_data_out;
    endclocking

    clocking mon_cb @(posedge clk);
        input reset;
        input inst_in_bits, is_load, is_store, is_branch, dest_tag_in_bits, rob_index;
        input load_execute_pack, store_execute_pack, store_retire_pack;
        input load_retire_valid, load_retire_num;
        input mispredicted, BS_lq_tail_in, BS_sq_tail_in;
        input dcache_can_accept_store, dcache_can_accept_load, dcache_load_packet;
        input sq_index, lq_index, sq_tail_out, sq_valid_out_mask;
        input sq_head_out, sq_valid_out, sq_addr_ready_out, sq_data_ready_out;
        input sq_addr_out, sq_data_out, sq_funct3_out, sq_out;
        input lq_space_available, sq_space_available, load_packet, cdb_req_load, lq_out;
    endclocking

    modport drv_mp(clocking drv_cb, input clk);
    modport mon_mp(clocking mon_cb, input clk);

    task automatic clear_inputs();
        drv_cb.inst_in_bits         <= '{default: '0};
        drv_cb.is_load              <= '0;
        drv_cb.is_store             <= '0;
        drv_cb.is_branch            <= '0;
        drv_cb.dest_tag_in_bits     <= '{default: '0};
        drv_cb.rob_index            <= '{default: '0};
        drv_cb.load_execute_pack    <= '0;
        drv_cb.store_execute_pack   <= '0;
        drv_cb.store_retire_pack    <= '{default: '0};
        drv_cb.load_retire_valid    <= 1'b0;
        drv_cb.load_retire_num      <= '0;
        drv_cb.mispredicted         <= 1'b0;
        drv_cb.BS_lq_tail_in        <= '0;
        drv_cb.BS_sq_tail_in        <= '0;
        drv_cb.dcache_can_accept_store <= 1'b1;
        drv_cb.dcache_can_accept_load  <= 1'b1;
        drv_cb.dcache_load_packet   <= '0;
    endtask

    task automatic apply_reset();
        @(negedge clk);
        drv_cb.reset <= 1'b1;
        clear_inputs();
        repeat (3) @(negedge clk);
        drv_cb.reset <= 1'b0;
        @(negedge clk);
    endtask

endinterface : lsq_if
`endif
