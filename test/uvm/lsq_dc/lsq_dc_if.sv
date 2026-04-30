// lsq_dc_if.sv — Combined interface for Load Queue + Store Queue + DCache UVM testbench
//
// Only externally-driven signals are here.  Internal connections between the
// three DUTs (LQ.load_packet → Dcache.load_req_pack, SQ→LQ forwarding arrays,
// Dcache.cache_resp_data → LQ.dcache_load_packet, etc.) are wired directly in
// lsq_dc_tb_top.sv and are NOT exposed through this interface.
`ifndef LSQ_DC_IF_SV
`define LSQ_DC_IF_SV
`include "sys_defs.svh"

interface lsq_dc_if (input logic clk);

    // ---- Shared reset ----
    logic reset;

    // ---- Dispatch inputs (shared by LQ + SQ) ----
    INST  [`N-1:0]  inst_in;        // instruction word (funct3 used for size)
    logic [`N-1:0]  is_load;        // slot i dispatches a load
    logic [`N-1:0]  is_store;       // slot i dispatches a store
    logic [`N-1:0]  is_branch;      // slot i dispatches a branch (snapshot trigger)
    ROB_IDX [`N-1:0] rob_index;     // ROB tag assigned at dispatch
    PRF_IDX [`N-1:0] dest_tag_in;   // destination physical register (loads only)

    // ---- Execute: load address fill ----
    LQ_PACKET  load_execute_pack;   // {valid, addr, lq_index, dest_tag, generation, ...}

    // ---- Execute: store address + data fill ----
    SQ_PACKET  store_execute_pack;  // {valid, addr, data, funct3, sq_index, rob_index}

    // ---- Retire stage ----
    SQ_PACKET  store_retire_pack [`N-1:0]; // stores being retired (committed to cache)
    logic      load_retire_valid;          // loads being retired (free LQ head entries)
    logic [1:0] load_retire_num;           // how many loads retire this cycle

    // ---- Mispredict recovery ----
    logic       mispredicted;
    LQ_IDX      BS_lq_tail_in;   // LQ tail snapshot to restore
    SQ_IDX      BS_sq_tail_in;   // SQ tail snapshot to restore

    // ---- Memory bus simulation (MSHR ↔ memory) ----
    MEM_TAG          mem2proc_transaction_tag;// transaction tag returned with grant
    MEM_TAG          mem2proc_data_tag;       // tag accompanying the returned data
    MEM_BLOCK        mem2proc_data;           // cache line data returned from memory
    logic            mshr_grant;              // CPU-like bus grant for MSHR loads
    logic            wb_grant;                // CPU-like bus grant for Dcache write buffer

    // ========================================================
    // Observable outputs (driven by DUTs, sampled by monitor)
    // ========================================================

    // ---- LQ outputs ----
    LQ_IDX  lq_index        [`N-1:0]; // allocated LQ slot per dispatch
    LQ_IDX  BS_lq_tail_out  [`N-1:0]; // tail snapshot for branch stack
    logic [1:0] lq_space_available;
    logic       cdb_req_load;          // LQ wants to broadcast via CDB
    LQ_PACKET   lq_out;                // CDB broadcast packet (data + dest_tag)

    // ---- SQ outputs ----
    SQ_IDX  sq_index        [`N-1:0];
    SQ_IDX  BS_sq_tail_out  [`N-1:0];
    logic [1:0] sq_space_available;

    // ---- Dcache outputs (observability only — MSHR connection is internal) ----
    miss_request_t miss_request;      // miss info forwarded from Dcache → MSHR (wire)
    logic          req_valid;         // Dcache has an active miss request
    logic          dcache_can_accept_load;
    logic          dcache_can_accept_store;
    completed_mshr_t com_miss_req;    // completed miss returned by MSHR to Dcache

    // ---- MSHR outputs (observable memory bus + miss-queue status) ----
    MEM_COMMAND    mshr2mem_command;  // MSHR → memory bus command
    ADDR           mshr2mem_addr;
    MEM_SIZE       mshr2mem_size;
    logic          miss_queue_full;   // MSHR FIFO full (observed, not driven)
    logic          miss_returned;     // MSHR signals line fill complete (observed)

    // ---- Write-buffer → memory bus (inside Dcache, observed for coverage) ----
    MEM_COMMAND    wb2mem_command;
    ADDR           wb2mem_addr;
    MEM_BLOCK      wb2mem_data;
    MEM_SIZE       wb2mem_size;

    // ============================================================
    // Clocking blocks
    // ============================================================

    // Driver: apply stimulus at negedge (setup time before next posedge)
    clocking drv_cb @(negedge clk);
        output reset;
        output inst_in, is_load, is_store, is_branch, rob_index, dest_tag_in;
        output load_execute_pack, store_execute_pack;
        output store_retire_pack, load_retire_valid, load_retire_num;
        output mispredicted, BS_lq_tail_in, BS_sq_tail_in;
        output mem2proc_transaction_tag, mem2proc_data_tag, mem2proc_data;
        output mshr_grant, wb_grant;
    endclocking

    // Monitor: sample all I/O at posedge
    clocking mon_cb @(posedge clk);
        // inputs applied before this edge
        input inst_in, is_load, is_store, is_branch, rob_index, dest_tag_in;
        input load_execute_pack, store_execute_pack;
        input store_retire_pack, load_retire_valid, load_retire_num;
        input mispredicted, BS_lq_tail_in, BS_sq_tail_in;
        input mem2proc_data_tag, mem2proc_data;
        // outputs produced after registered state
        input lq_index, BS_lq_tail_out, lq_space_available;
        input cdb_req_load, lq_out;
        input sq_index, BS_sq_tail_out, sq_space_available;
        input miss_request, req_valid;
        input com_miss_req;
        input miss_returned, miss_queue_full;
        input mshr2mem_command, mshr2mem_addr, mshr2mem_size;
        input wb2mem_command, wb2mem_addr, wb2mem_data, wb2mem_size;
        input dcache_can_accept_load, dcache_can_accept_store;
    endclocking

    // 给外部看的
    modport drv_mp (clocking drv_cb, input clk);
    modport mon_mp (clocking mon_cb, input clk);

    task automatic apply_reset();
        @(negedge clk);
        drv_cb.reset              <= 1;
        drv_cb.inst_in            <= '{default: '0};
        drv_cb.is_load            <= '0;
        drv_cb.is_store           <= '0;
        drv_cb.is_branch          <= '0;
        drv_cb.rob_index          <= '{default: '0};
        drv_cb.dest_tag_in        <= '{default: '0};
        drv_cb.load_execute_pack  <= '0;
        drv_cb.store_execute_pack <= '0;
        drv_cb.store_retire_pack  <= '{default: '0};
        drv_cb.load_retire_valid  <= 0;
        drv_cb.load_retire_num    <= 0;
        drv_cb.mispredicted       <= 0;
        drv_cb.BS_lq_tail_in      <= '0;
        drv_cb.BS_sq_tail_in      <= '0;
        drv_cb.mem2proc_transaction_tag <= '0;
        drv_cb.mem2proc_data_tag  <= '0;
        drv_cb.mem2proc_data      <= '0;
        drv_cb.mshr_grant         <= 1; // default: grant memory load path
        drv_cb.wb_grant           <= 1; // default: grant write-buffer path
        @(negedge clk);
        drv_cb.reset <= 0;
        @(negedge clk);
    endtask

endinterface : lsq_dc_if
`endif
