// memsys_tb_top.sv - Top-level UVM harness for Dcache + MSHR subsystem.
`timescale 1ns/100ps
`include "sys_defs.svh"
`include "test/uvm/memsys/memsys_if.sv"

import uvm_pkg::*;
`include "uvm_macros.svh"
import memsys_pkg::*;

module memsys_tb_top;

    logic clk;
    initial clk = 1'b0;
    always #(`CLOCK_PERIOD / 2.0) clk = ~clk;

    memsys_if mif(.clk(clk));

    completed_mshr_t com_miss_req;

    Dcache dcache_dut (
        .clock                    (clk),
        .reset                    (mif.reset),
        .load_req_pack            (mif.load_req_pack),
        .store_req_pack           (mif.store_req_pack),

        .com_miss_req             (com_miss_req),
        .miss_returned            (mif.miss_returned),
        .miss_queue_full          (mif.miss_queue_full),
        .mem2proc_transaction_tag (mif.mem2proc_transaction_tag),

        .grant                    (mif.grant),

        .cache_resp_data          (mif.cache_resp_data),
        .miss_request             (mif.miss_request),
        .req_valid                (),

        .wb2mem_command           (mif.wb2mem_command),
        .wb2mem_addr              (mif.wb2mem_addr),
        .wb2mem_data              (mif.wb2mem_data),
        .wb2mem_size              (mif.wb2mem_size),

        .dcache_can_accept_store  (mif.dcache_can_accept_store),
        .dcache_can_accept_load   (mif.dcache_can_accept_load),

        .dcache_debug_data        (mif.dcache_debug_data),
        .dcache_debug_tags        (mif.dcache_debug_tags),
        .debug_vc_entries         (mif.debug_vc_entries),
        .debug_write_buff         (mif.debug_write_buff)
    );

    mshr mshr_dut (
        .clock                    (clk),
        .reset                    (mif.reset),
        .grant                    (mif.grant),

        .dcache_miss_req          (mif.miss_request),

        .mem2proc_transaction_tag (mif.mem2proc_transaction_tag),
        .mem2proc_data_tag        (mif.mem2proc_data_tag),
        .mem2proc_data            (mif.mem2proc_data),

        .mshr2mem_command         (mif.mshr2mem_command),
        .mshr2mem_addr            (mif.mshr2mem_addr),
        .mshr2mem_size            (mif.mshr2mem_size),
        .mshr2mem_data            (mif.mshr2mem_data),
        .com_miss_req             (com_miss_req),
        .miss_queue_full          (mif.miss_queue_full),
        .miss_returned            (mif.miss_returned),
        .mshr_wait_for_trans      (mif.mshr_wait_for_trans),
        .mshr_currently_waiting   (mif.mshr_currently_waiting)
    );

    always_comb begin
        mif.dcache_hit    = dcache_dut.hit;
        mif.vc_hit        = dcache_dut.vc_hit;
        mif.wb_hit        = dcache_dut.wb_hit;
        mif.wb_full       = dcache_dut.wb_full;
        mif.vcache_accept = dcache_dut.vcache_accept;
    end

    initial begin
        uvm_config_db #(virtual memsys_if)::set(
            uvm_root::get(), "uvm_test_top.*", "memsys_vif", mif);
        run_test("memsys_directed_test");
    end

    initial begin
        #(2_000_000);
        `uvm_fatal("TIMEOUT", "Memory-subsystem UVM simulation exceeded 2 ms")
    end

endmodule : memsys_tb_top
