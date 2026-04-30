// rob_tb_top.sv — UVM testbench top module for the ROB
// Instantiates interface + DUT, provides clock, and launches UVM.
//
// Usage:
//   make rob_uvm.pass                        (runs rob_rand_test)
//   make rob_uvm.pass UVM_TEST=rob_directed_test
`timescale 1ns/100ps
`include "sys_defs.svh"
`include "test/uvm/rob/rob_if.sv"

import uvm_pkg::*;
`include "uvm_macros.svh"
import rob_pkg::*;

module rob_tb_top;

    // ---- Clock ----
    logic clk;
    initial clk = 0;
    always #(`CLOCK_PERIOD / 2.0) clk = ~clk;

    // ---- Interface instance ----
    rob_if rif (.clk(clk));

    // ---- DUT instantiation ----
    rob dut (
        .clock          (clk),
        .reset          (rif.reset),
        .dispatch_pack  (rif.dispatch_pack),
        .is_branch      (rif.is_branch),
        .mispredicted   (rif.mispredicted),
        .rob_tail_in    (rif.rob_tail_in),
        .cdb            (rif.cdb),
        .cond_branch_in (rif.cond_branch_in),
        .sq_in          (rif.sq_in),
        .halt_safe      (rif.halt_safe),
        .rob_commit     (rif.rob_commit),
        .rob_space_avail(rif.rob_space_avail),
        .rob_index      (rif.rob_index),
        .rob_tail_out   (rif.rob_tail_out)
    );

    // ---- UVM startup ----
    initial begin
        // Publish the virtual interface to all UVM components via config_db.
        // The key "rob_vif" matches what the driver and monitor use in get().
        uvm_config_db #(virtual rob_if)::set(
            uvm_root::get(), "uvm_test_top.*", "rob_vif", rif);

        // Apply hardware reset before UVM runs
        rif.apply_reset();

        // Run the test chosen by +UVM_TESTNAME= plusarg (default: rob_rand_test)
        run_test("rob_rand_test");
    end

    // ---- Timeout watchdog ----
    initial begin
        #(500_000); // 500 us
        `uvm_fatal("TIMEOUT", "Simulation exceeded 500 us — possible hang")
    end

endmodule : rob_tb_top
