// memsys_if.sv - UVM interface for Dcache + MSHR memory subsystem tests.
`ifndef MEMSYS_IF_SV
`define MEMSYS_IF_SV
`include "sys_defs.svh"

interface memsys_if(input logic clk);

    logic reset;
    logic grant;

    LQ_PACKET load_req_pack;
    SQ_PACKET store_req_pack;

    MEM_TAG   mem2proc_transaction_tag;
    MEM_TAG   mem2proc_data_tag;
    MEM_BLOCK mem2proc_data;

    dcache_data_t  cache_resp_data;
    miss_request_t miss_request;
    logic          dcache_can_accept_store;
    logic          dcache_can_accept_load;

    MEM_COMMAND wb2mem_command;
    ADDR        wb2mem_addr;
    MEM_BLOCK   wb2mem_data;
    MEM_SIZE    wb2mem_size;

    MEM_COMMAND mshr2mem_command;
    ADDR        mshr2mem_addr;
    MEM_SIZE    mshr2mem_size;
    MEM_BLOCK   mshr2mem_data;
    logic       miss_queue_full;
    logic       miss_returned;
    logic       mshr_wait_for_trans;
    logic       mshr_currently_waiting;

    MEM_BLOCK   [`DCACHE_SETS-1:0][`DCACHE_WAYS-1:0] dcache_debug_data;
    cache_tag_t [`DCACHE_SETS-1:0][`DCACHE_WAYS-1:0] dcache_debug_tags;
    vc_entry_t  [`VC_LINES-1:0]                       debug_vc_entries;
    wb_entry_t  [`WB_ENTRIES-1:0]                     debug_write_buff;

    // Top-level hierarchical probes. These are observability-only; stimulus
    // still goes through the architectural interfaces above.
    logic dcache_hit;
    logic vc_hit;
    logic wb_hit;
    logic wb_full;
    logic vcache_accept;

    clocking drv_cb @(negedge clk);
        output reset, grant;
        output load_req_pack, store_req_pack;
        output mem2proc_transaction_tag, mem2proc_data_tag, mem2proc_data;

        input cache_resp_data, miss_request;
        input dcache_can_accept_store, dcache_can_accept_load;
        input wb2mem_command, wb2mem_addr, wb2mem_data, wb2mem_size;
        input mshr2mem_command, mshr2mem_addr, mshr2mem_size, mshr2mem_data;
        input miss_queue_full, miss_returned, mshr_wait_for_trans, mshr_currently_waiting;
        input dcache_hit, vc_hit, wb_hit, wb_full, vcache_accept;
        input debug_vc_entries, debug_write_buff, dcache_debug_tags, dcache_debug_data;
    endclocking

    clocking mon_cb @(posedge clk);
        input reset, grant;
        input load_req_pack, store_req_pack;
        input mem2proc_transaction_tag, mem2proc_data_tag, mem2proc_data;
        input cache_resp_data, miss_request;
        input dcache_can_accept_store, dcache_can_accept_load;
        input wb2mem_command, wb2mem_addr, wb2mem_data, wb2mem_size;
        input mshr2mem_command, mshr2mem_addr, mshr2mem_size, mshr2mem_data;
        input miss_queue_full, miss_returned, mshr_wait_for_trans, mshr_currently_waiting;
        input dcache_hit, vc_hit, wb_hit, wb_full, vcache_accept;
        input debug_vc_entries, debug_write_buff, dcache_debug_tags, dcache_debug_data;
    endclocking

    modport drv_mp(clocking drv_cb, input clk);
    modport mon_mp(clocking mon_cb, input clk);

    task automatic clear_core_req();
        drv_cb.load_req_pack  <= '0;
        drv_cb.store_req_pack <= '0;
    endtask

    task automatic clear_mem_rsp();
        drv_cb.mem2proc_transaction_tag <= '0;
        drv_cb.mem2proc_data_tag        <= '0;
        drv_cb.mem2proc_data            <= '0;
    endtask

    task automatic clear_inputs();
        clear_core_req();
        clear_mem_rsp();
        drv_cb.grant <= 1'b1;
    endtask

    task automatic apply_reset();
        @(negedge clk);
        drv_cb.reset <= 1'b1;
        clear_inputs();
        repeat (4) @(negedge clk);
        drv_cb.reset <= 1'b0;
        @(negedge clk);
    endtask

endinterface : memsys_if
`endif
