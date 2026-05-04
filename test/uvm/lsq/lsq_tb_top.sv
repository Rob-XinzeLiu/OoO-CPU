// lsq_tb_top.sv - Top-level UVM harness for split LQ/SQ.
`timescale 1ns/100ps
`include "sys_defs.svh"
`include "test/uvm/lsq/lsq_if.sv"

import uvm_pkg::*;
`include "uvm_macros.svh"
import lsq_pkg::*;

module lsq_tb_top;

    logic clk;
    initial clk = 1'b0;
    always #(`CLOCK_PERIOD / 2.0) clk = ~clk;

    lsq_if lif(.clk(clk));

    INST    [`N-1:0] dut_inst_in;
    PRF_IDX [`N-1:0] dut_dest_tag_in;

    always_comb begin
        for (int i = 0; i < `N; i++) begin
            dut_inst_in[i].inst = lif.inst_in_bits[i];
            dut_dest_tag_in[i]  = PRF_IDX'(lif.dest_tag_in_bits[i]);
        end
    end

    store_queue sq_dut (
        .clock                 (clk),
        .reset                 (lif.reset),
        .inst_in               (dut_inst_in),
        .is_load               (lif.is_load),
        .is_store              (lif.is_store),
        .is_branch             (lif.is_branch),
        .rob_index             (lif.rob_index),
        .store_execute_pack    (lif.store_execute_pack),
        .store_retire_pack     (lif.store_retire_pack),
        .mispredicted          (lif.mispredicted),
        .BS_sq_tail_in         (lif.BS_sq_tail_in),
        .dcache_can_accept     (lif.dcache_can_accept_store),
        .sq_out                (lif.sq_out),
        .BS_sq_tail_out        (lif.BS_sq_tail_out),
        .sq_space_available    (lif.sq_space_available),
        .sq_addr_ready_mask    (lif.sq_addr_ready_mask),
        .sq_index              (lif.sq_index),
        .sq_head_out           (lif.sq_head_out),
        .sq_addr_out           (lif.sq_addr_out),
        .sq_addr_ready_out     (lif.sq_addr_ready_out),
        .sq_data_out           (lif.sq_data_out),
        .sq_data_ready_out     (lif.sq_data_ready_out),
        .sq_funct3_out         (lif.sq_funct3_out),
        .sq_valid_out          (lif.sq_valid_out),
        .sq_valid_out_mask     (lif.sq_valid_out_mask),
        .sq_tail_out           (lif.sq_tail_out)
    );

    load_queue lq_dut (
        .clock                 (clk),
        .reset                 (lif.reset),
        .inst_in               (dut_inst_in),
        .is_load               (lif.is_load),
        .is_branch             (lif.is_branch),
        .dest_tag_in           (dut_dest_tag_in),
        .rob_index             (lif.rob_index),
        .load_retire_valid     (lif.load_retire_valid),
        .load_retire_num       (lif.load_retire_num),
        .mispredicted          (lif.mispredicted),
        .BS_lq_tail_in         (lif.BS_lq_tail_in),
        .sq_addr_in            (lif.sq_addr_out),
        .sq_addr_ready_in      (lif.sq_addr_ready_out),
        .sq_data_in            (lif.sq_data_out),
        .sq_data_ready_in      (lif.sq_data_ready_out),
        .sq_valid_in           (lif.sq_valid_out),
        .sq_valid_in_mask      (lif.sq_valid_out_mask),
        .sq_tail_in            (lif.sq_tail_out),
        .sq_funct3_in          (lif.sq_funct3_out),
        .sq_head_in            (lif.sq_head_out),
        .load_execute_pack     (lif.load_execute_pack),
        .dcache_can_accept_load(lif.dcache_can_accept_load),
        .dcache_load_packet    (lif.dcache_load_packet),
        .lq_index              (lif.lq_index),
        .BS_lq_tail_out        (lif.BS_lq_tail_out),
        .lq_space_available    (lif.lq_space_available),
        .load_packet           (lif.load_packet),
        .cdb_req_load          (lif.cdb_req_load),
        .lq_out                (lif.lq_out)
    );

    initial begin
        uvm_config_db #(virtual lsq_if)::set(
            uvm_root::get(), "uvm_test_top.*", "lsq_vif", lif);
        run_test("lsq_directed_test");
    end

    initial begin
        #(500_000);
        `uvm_fatal("TIMEOUT", "LSQ UVM simulation exceeded 500 us")
    end

endmodule : lsq_tb_top
