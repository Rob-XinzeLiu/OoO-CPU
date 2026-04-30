// rob_if.sv — ROB DUT interface with clocking blocks for UVM
// Passed into UVM hierarchy via uvm_config_db as virtual rob_if.
`ifndef ROB_IF_SV
`define ROB_IF_SV
`include "sys_defs.svh"

interface rob_if (input logic clk);

    // ---- Inputs to DUT ----
    logic               reset;
    logic               halt_safe;
    D_S_PACKET          dispatch_pack  [`N-1:0];
    logic   [`N-1:0]    is_branch;
    logic               mispredicted;
    ROB_IDX             rob_tail_in;
    X_C_PACKET          cdb            [`N-1:0];
    COND_BRANCH_PACKET  cond_branch_in;
    SQ_PACKET           sq_in;

    // ---- Outputs from DUT ----
    RETIRE_PACKET       rob_commit     [`N-1:0];
    logic  [1:0]        rob_space_avail;
    ROB_IDX             rob_index      [`N-1:0];
    ROB_IDX             rob_tail_out   [`N-1:0];

    // Driver drives all inputs at negedge (gives DUT setup time before posedge).
    clocking drv_cb @(negedge clk);
        output reset, halt_safe;
        output dispatch_pack, is_branch;
        output mispredicted, rob_tail_in;
        output cdb, cond_branch_in, sq_in;
    endclocking

    // Monitor samples all signals at posedge (after registered state settles).
    // SV clocking-block inputs are captured in the preponed region, so we see
    // the state that was committed by the previous negedge stimulus.
    clocking mon_cb @(posedge clk);
        input dispatch_pack, is_branch;
        input mispredicted, rob_tail_in, cdb;
        input rob_commit, rob_space_avail;
        input rob_index, rob_tail_out;
    endclocking

    modport drv_mp (clocking drv_cb, input clk);
    modport mon_mp (clocking mon_cb, input clk);

    // Convenience task used by rob_tb_top to apply reset
    task automatic apply_reset();
        @(negedge clk);
        drv_cb.reset          <= 1;
        drv_cb.halt_safe      <= 1;
        drv_cb.dispatch_pack  <= '{default: '0};
        drv_cb.is_branch      <= '0;
        drv_cb.mispredicted   <= 0;
        drv_cb.rob_tail_in    <= '0;
        drv_cb.cdb            <= '{default: '0};
        drv_cb.cond_branch_in <= '0;
        drv_cb.sq_in          <= '0;
        @(negedge clk);
        drv_cb.reset <= 0;
        @(negedge clk);
    endtask

endinterface : rob_if
`endif // ROB_IF_SV
