// lsq_dc_tb_top.sv — UVM testbench top for Load Queue + Store Queue + DCache + MSHR
//
// Instantiates four DUTs and wires their internal connections:
//   LQ.load_packet  ──────────────────────→ Dcache.load_req_pack
//   SQ.sq_out       ──────────────────────→ Dcache.store_req_pack
//   Dcache.cache_resp_data ───────────────→ LQ.dcache_load_packet
//   Dcache.dcache_can_accept_load ────────→ LQ.dcache_can_accept_load
//   Dcache.dcache_can_accept_store ───────→ SQ.dcache_can_accept
//   SQ.sq_addr/data/funct3/valid arrays ──→ LQ store-to-load forwarding inputs
//   SQ.sq_head_out, sq_tail_out, sq_index → LQ forwarding control
//   Dcache.miss_request / req_valid ──────→ MSHR.dcache_miss_req (miss path)
//   MSHR.com_miss_req / miss_returned ───→ Dcache.com_miss_req / miss_returned
//   MSHR.miss_queue_full ─────────────────→ Dcache.miss_queue_full
//
// Usage:
//   make lsq_dc_uvm.pass
//   make lsq_dc_uvm.pass UVM_TEST=lsq_dc_smoke_test
//   make lsq_dc_uvm.pass UVM_TEST=lsq_dc_directed_test
`timescale 1ns/100ps
`include "sys_defs.svh"
`include "test/uvm/lsq_dc/lsq_dc_if.sv"

import uvm_pkg::*;
`include "uvm_macros.svh"
import lsq_dc_pkg::*;

module lsq_dc_tb_top;

    // ---- Clock ----
    logic clk;
    initial clk = 0;
    always #(`CLOCK_PERIOD / 2.0) clk = ~clk;

    // ---- Interface ----
    lsq_dc_if ifc (.clk(clk));

    // =========================================================
    // Internal wires connecting the three DUTs
    // =========================================================

    // LQ → Dcache (load request)
    LQ_PACKET  lq_load_packet;

    // SQ → Dcache (store commit)
    SQ_PACKET  sq_store_out;

    // Dcache → LQ (load response)
    dcache_data_t dcache_to_lq_resp;
    logic         dc_can_accept_load;
    logic         dc_can_accept_store;

    // SQ → LQ forwarding arrays
    ADDR               sq_addr_fwd       [`SQ_SZ-1:0];
    logic              sq_addr_ready_fwd [`SQ_SZ-1:0];
    DATA               sq_data_fwd       [`SQ_SZ-1:0];
    logic              sq_data_ready_fwd [`SQ_SZ-1:0];
    logic [2:0]        sq_funct3_fwd [`SQ_SZ-1:0];
    logic [`SQ_SZ-1:0] sq_valid_fwd;
    logic [`SQ_SZ-1:0] sq_valid_mask_fwd [`N-1:0];
    SQ_IDX             sq_tail_fwd   [`N-1:0];
    SQ_IDX             sq_head_fwd;

    // Dcache → MSHR (miss request)
    miss_request_t dc_miss_req;
    logic          dc_req_valid;

    // MSHR → Dcache (fill path)
    completed_mshr_t mshr_com_miss_req;
    logic            mshr_miss_returned;
    logic            mshr_miss_queue_full;

    // MSHR debug outputs (unused wires — connect to avoid undriven warnings)
    MEM_BLOCK        mshr_dbg_data;
    logic            mshr_wait_for_trans;
    logic            mshr_currently_waiting;

    // Dcache debug (unused in UVM but required by port list)
    MEM_BLOCK  [`DCACHE_SETS-1:0][`DCACHE_WAYS-1:0] dbg_data;
    cache_tag_t[`DCACHE_SETS-1:0][`DCACHE_WAYS-1:0] dbg_tags;
    vc_entry_t [`VC_LINES-1:0]                       dbg_vc;
    wb_entry_t [`WB_ENTRIES-1:0]                     dbg_wb;

    // =========================================================
    // DUT 1: Load Queue
    // =========================================================
    load_queue lq_dut (
        .clock                (clk),
        .reset                (ifc.reset),
        // dispatch
        .inst_in              (ifc.inst_in),
        .is_load              (ifc.is_load),
        .is_branch            (ifc.is_branch),
        .dest_tag_in          (ifc.dest_tag_in),
        .rob_index            (ifc.rob_index),
        // retire
        .load_retire_valid    (ifc.load_retire_valid),
        .load_retire_num      (ifc.load_retire_num),
        // mispredict
        .mispredicted         (ifc.mispredicted),
        .BS_lq_tail_in        (ifc.BS_lq_tail_in),
        // store-to-load forwarding (from SQ)
        .sq_addr_in           (sq_addr_fwd),
        .sq_addr_ready_in     (sq_addr_ready_fwd),
        .sq_data_in           (sq_data_fwd),
        .sq_data_ready_in     (sq_data_ready_fwd),
        .sq_valid_in          (sq_valid_fwd),
        .sq_valid_in_mask     (sq_valid_mask_fwd),
        .sq_tail_in           (sq_tail_fwd),
        .sq_funct3_in         (sq_funct3_fwd),
        .sq_head_in           (sq_head_fwd),
        // address from execute stage
        .load_execute_pack    (ifc.load_execute_pack),
        // dcache interface
        .dcache_can_accept_load (dc_can_accept_load),
        .dcache_load_packet   (dcache_to_lq_resp),
        // outputs
        .lq_index             (ifc.lq_index),
        .BS_lq_tail_out       (ifc.BS_lq_tail_out),
        .lq_space_available   (ifc.lq_space_available),
        .load_packet          (lq_load_packet),
        .cdb_req_load         (ifc.cdb_req_load),
        .lq_out               (ifc.lq_out)
    );

    // =========================================================
    // DUT 2: Store Queue
    // =========================================================
    store_queue sq_dut (
        .clock                (clk),
        .reset                (ifc.reset),
        // dispatch
        .inst_in              (ifc.inst_in),
        .is_load              (ifc.is_load),
        .is_store             (ifc.is_store),
        .is_branch            (ifc.is_branch),
        .rob_index            (ifc.rob_index),
        // execute: address + data fill
        .store_execute_pack   (ifc.store_execute_pack),
        // retire
        .store_retire_pack    (ifc.store_retire_pack),
        // mispredict
        .mispredicted         (ifc.mispredicted),
        .BS_sq_tail_in        (ifc.BS_sq_tail_in),
        // dcache backpressure
        .dcache_can_accept    (dc_can_accept_store),
        // outputs
        .sq_out               (sq_store_out),
        .BS_sq_tail_out       (ifc.BS_sq_tail_out),
        .sq_space_available   (ifc.sq_space_available),
        .sq_addr_ready_mask   (/* to RS, not tested here */),
        .sq_index             (ifc.sq_index),
        .sq_head_out          (sq_head_fwd),
        // forwarding arrays → LQ
        .sq_addr_out          (sq_addr_fwd),
        .sq_addr_ready_out    (sq_addr_ready_fwd),
        .sq_data_out          (sq_data_fwd),
        .sq_data_ready_out    (sq_data_ready_fwd),
        .sq_funct3_out        (sq_funct3_fwd),
        .sq_valid_out         (sq_valid_fwd),
        .sq_valid_out_mask    (sq_valid_mask_fwd),
        .sq_tail_out          (sq_tail_fwd)
    );

    // =========================================================
    // DUT 3: DCache
    // =========================================================
    Dcache #(
        .WAYS(`DCACHE_WAYS),
        .SETS(`DCACHE_SETS)
    ) dcache_dut (
        .clock                   (clk),
        .reset                   (ifc.reset),
        // requests from LQ and SQ
        .load_req_pack           (lq_load_packet),
        .store_req_pack          (sq_store_out),
        // miss path — filled by MSHR (internal wires)
        .com_miss_req            (mshr_com_miss_req),
        .miss_returned           (mshr_miss_returned),
        .miss_queue_full         (mshr_miss_queue_full),
        .mem2proc_transaction_tag(ifc.mem2proc_transaction_tag),
        .grant                   (ifc.wb_grant),
        // response to LQ
        .cache_resp_data         (dcache_to_lq_resp),
        // miss request → MSHR (internal wire, also forwarded to interface for monitoring)
        .miss_request            (dc_miss_req),
        .req_valid               (dc_req_valid),
        // write-buffer → memory bus
        .wb2mem_command          (ifc.wb2mem_command),
        .wb2mem_addr             (ifc.wb2mem_addr),
        .wb2mem_data             (ifc.wb2mem_data),
        .wb2mem_size             (ifc.wb2mem_size),
        // backpressure → LQ and SQ
        .dcache_can_accept_store (dc_can_accept_store),
        .dcache_can_accept_load  (dc_can_accept_load),
        // debug
        .dcache_debug_data       (dbg_data),
        .dcache_debug_tags       (dbg_tags),
        .debug_vc_entries        (dbg_vc),
        .debug_write_buff        (dbg_wb)
    );

    // =========================================================
    // DUT 4: MSHR
    // =========================================================
    mshr mshr_dut (
        .clock                   (clk),
        .reset                   (ifc.reset),
        .grant                   (ifc.mshr_grant),
        // miss request from Dcache
        .dcache_miss_req         (dc_miss_req),
        // memory bus return path (driver-controlled)
        .mem2proc_transaction_tag(ifc.mem2proc_transaction_tag),
        .mem2proc_data_tag       (ifc.mem2proc_data_tag),
        .mem2proc_data           (ifc.mem2proc_data),
        // outputs → Dcache fill path
        .com_miss_req            (mshr_com_miss_req),
        .miss_returned           (mshr_miss_returned),
        .miss_queue_full         (mshr_miss_queue_full),
        // memory bus request outputs (observed via interface)
        .mshr2mem_command        (ifc.mshr2mem_command),
        .mshr2mem_addr           (ifc.mshr2mem_addr),
        .mshr2mem_size           (ifc.mshr2mem_size),
        .mshr2mem_data           (mshr_dbg_data),          // unused in UVM
        .mshr_wait_for_trans     (mshr_wait_for_trans),    // unused
        .mshr_currently_waiting  (mshr_currently_waiting)  // unused
    );

    // Forward internal signals to interface for monitor observability
    assign ifc.miss_request            = dc_miss_req;
    assign ifc.req_valid               = dc_req_valid;
    assign ifc.com_miss_req            = mshr_com_miss_req;
    assign ifc.miss_returned           = mshr_miss_returned;
    assign ifc.miss_queue_full         = mshr_miss_queue_full;
    assign ifc.dcache_can_accept_load  = dc_can_accept_load;
    assign ifc.dcache_can_accept_store = dc_can_accept_store;

    // =========================================================
    // UVM startup
    // =========================================================
    initial begin
        uvm_config_db #(virtual lsq_dc_if)::set(
            uvm_root::get(), "uvm_test_top.*", "lsq_dc_vif", ifc);
        run_test("lsq_dc_rand_test");
    end

    // Watchdog
    initial begin
        #(1_000_000);
        `uvm_fatal("TIMEOUT", "Simulation exceeded 1 ms — possible hang")
    end

endmodule : lsq_dc_tb_top
