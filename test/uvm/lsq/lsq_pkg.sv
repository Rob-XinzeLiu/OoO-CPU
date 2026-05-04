// lsq_pkg.sv - Package entry point for the split LSQ UVM testbench.
`ifndef LSQ_PKG_SV
`define LSQ_PKG_SV
`include "sys_defs.svh"

import uvm_pkg::*;

package lsq_pkg;
    import uvm_pkg::*;
    import sys_defs_pkg::*;
    `include "uvm_macros.svh"

    `include "test/uvm/lsq/lsq_types.svh"
    `include "test/uvm/lsq/lsq_sequences.svh"
    `include "test/uvm/lsq/lsq_driver.svh"
    `include "test/uvm/lsq/lsq_monitor.svh"
    `include "test/uvm/lsq/lsq_agent.svh"
    `include "test/uvm/lsq/lsq_scoreboard.svh"
    `include "test/uvm/lsq/lsq_coverage.svh"
    `include "test/uvm/lsq/lsq_env.svh"
    `include "test/uvm/lsq/lsq_tests.svh"

endpackage : lsq_pkg
`endif
