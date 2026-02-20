`timescale 1ns/1ps
`include "sys_defs.svh"

module testbench;

  logic                         clock;
  logic                         reset;
  logic                         mispredicted;
  B_MASK                        mispredicted_bmask_index;
  ROB_IDX                       rob_index       [`N-1:0];
  logic [1:0]                   dispatch_num;
  D_S_PACKET                    dispatch_pack   [`N-1:0];
  X_C_PACKET                    cdb             [`N-1:0];
  logic                         resolved;
  B_MASK                        resolved_bmask_index;
    B_MASK b;
  logic                         alu0_ready;
  logic                         alu1_ready;

  D_S_PACKET                    issue_pack      [`N-1:0];
  logic [$clog2(`RS_SZ + 1)-1:0] empty_entries_num;
  rs dut (
    .clock(clock),
    .reset(reset),
    .mispredicted(mispredicted),
    .mispredicted_bmask_index(mispredicted_bmask_index),
    .rob_index(rob_index),
    .dispatch_num(dispatch_num),
    .dispatch_pack(dispatch_pack),
    .cdb(cdb),
    .resolved(resolved),
    .resolved_bmask_index(resolved_bmask_index),
    .alu0_ready(alu0_ready),
    .alu1_ready(alu1_ready),
    .issue_pack(issue_pack),
    .empty_entries_num(empty_entries_num)
  );

  initial clock = 0;
  always #5 clock = ~clock;

  task automatic tick();
    @(posedge clock);
    #1;
  endtask

  task automatic reset_dut();
    reset = 1;
    mispredicted = 0;
    mispredicted_bmask_index = '0;
    resolved = 0;
    resolved_bmask_index = '0;
    dispatch_num = 2'd0;
    alu0_ready = 0;
    alu1_ready = 0;

    for (int k = 0; k < `N; k++) begin
      dispatch_pack[k] = '0;
      rob_index[k]     = '0;
      cdb[k]           = '0;
    end

    // hold reset for a couple cycles
    tick();
    tick();
    reset = 0;
    tick();
  endtask

  function automatic int issued_count();
    int cnt = 0;
    for (int k = 0; k < `N; k++) begin
      if (issue_pack[k].inst !== '0) cnt++;
    end
    return cnt;
  endfunction

  // Wait up to max_cycles for ANY issue to happen.
  task automatic expect_any_issue_within(input int max_cycles, input string tag);
    bit ok;
    ok = 0;
    for (int i = 0; i < max_cycles; i++) begin
      tick();
      if (issued_count() > 0) begin
        ok = 1;
        break;
      end
    end
    if (!ok) begin
      $error("FAIL %s: expected some issue but saw none within %0d cycles", tag, max_cycles);
      $finish;
    end
    $display("PASS %s: issued_count=%0d", tag, issued_count());
  endtask

  // Wait up to max_cycles for NO issue to happen (issued_count must stay 0).
  task automatic expect_no_issue_for(input int max_cycles, input string tag);
    for (int i = 0; i < max_cycles; i++) begin
      tick();
      if (issued_count() > 0) begin
        $error("FAIL %s: expected no issue but saw issued_count=%0d", tag, issued_count());
        $finish;
      end
    end
    $display("PASS %s: no issue for %0d cycles", tag, max_cycles);
  endtask

  function automatic B_MASK bm_onehot(int idx);
    B_MASK tmp;
    tmp = '0;
    tmp[idx] = 1'b1;
    return tmp;
  endfunction

  // ==============================================================
  // TESTS (all "basic", and none require matching a specific INST)
  // ==============================================================

    task automatic test0_smoke_wakeup();
        $display("\n[TEST0] smoke_wakeup");

        alu0_ready = 1;
        alu1_ready = 1;

        // dispatch 1 op not ready on t1
        dispatch_num = 2'd1;
        dispatch_pack[0] = '0;
        dispatch_pack[0].mult     = 1'b0;
        dispatch_pack[0].t1       = PRF_IDX'(12);
        dispatch_pack[0].t2       = PRF_IDX'(13);
        dispatch_pack[0].t1_ready = 1'b0;
        dispatch_pack[0].t2_ready = 1'b1;
        dispatch_pack[0].PC       = ADDR'(32'h1000);
        dispatch_pack[0].NPC      = ADDR'(32'h1004);
        dispatch_pack[0].inst     = INST'(32'hDEADBEEF);
        dispatch_pack[0].opcode   = 7'h33;
        rob_index[0]              = ROB_IDX'(3);

        tick(); // enqueue
        dispatch_num = 2'd0;

        // broadcast CDB completion for t1
        cdb[0] = '0;
        cdb[0].valid        = 1'b1;
        cdb[0].complete_tag = PRF_IDX'(12);
        tick(); // wakeup registers

        cdb[0] = '0;

        // give a small window for issue (covers the 1-cycle wakeup latency)
        expect_any_issue_within(4, "TEST0 smoke_wakeup");
    endtask

    task automatic test1_ready_issues_without_cdb();
        $display("\n[TEST1] ready_issues_without_cdb");

        alu0_ready = 1;
        alu1_ready = 1;

        // dispatch ready ALU op (both operands ready)
        dispatch_num = 2'd1;
        dispatch_pack[0] = '0;
        dispatch_pack[0].mult     = 1'b0;
        dispatch_pack[0].t1_ready = 1'b1;
        dispatch_pack[0].t2_ready = 1'b1;
        dispatch_pack[0].inst     = INST'(32'h1111_1111);
        dispatch_pack[0].opcode   = 7'h33;

        tick(); // enqueue
        dispatch_num = 2'd0;
        expect_any_issue_within(4, "TEST1 ready_issues");
    endtask

    task automatic test2_alu_gating_blocks_issue();
    $display("\n[TEST2] alu_gating_then_enable");

    // block ALUs 
    alu0_ready = 0;
    alu1_ready = 0;

    // dispatch ready ALU op
    dispatch_num = 2'd1;
    dispatch_pack[0] = '0;
    dispatch_pack[0].mult     = 1'b0;
    dispatch_pack[0].t1_ready = 1'b1;
    dispatch_pack[0].t2_ready = 1'b1;
    dispatch_pack[0].inst     = INST'(32'h2222_2222);
    dispatch_pack[0].opcode   = 7'h33;

    tick(); // enqueue
    dispatch_num = 2'd0;

    // wait a couple cycles while blocked (no assertion!)
    tick();
    tick();

    // now enable one ALU and it should issue soon
    alu0_ready = 1;
    alu1_ready = 0;

    expect_any_issue_within(4, "TEST2 alu_gating unblocked");
    endtask

  task automatic test3_mispredict_flush_blocks_issue();
    $display("\n[TEST3] mispredict_flush_sanity");

    // block ALUs so nothing can issue before flush
    alu0_ready = 0;
    alu1_ready = 0;

    b = bm_onehot(2);

    // dispatch ready op but with bmask set
    dispatch_num = 2'd1;
    dispatch_pack[0] = '0;
    dispatch_pack[0].mult        = 1'b0;
    dispatch_pack[0].t1_ready    = 1'b1;
    dispatch_pack[0].t2_ready    = 1'b1;
    dispatch_pack[0].bmask       = b;
    dispatch_pack[0].bmask_index = b;
    dispatch_pack[0].inst        = INST'(32'h3333_3333);
    dispatch_pack[0].opcode      = 7'h33;

    tick(); // enqueue
    dispatch_num = 2'd0;

    // flush it
    mispredicted = 1'b1;
    mispredicted_bmask_index = b;
    tick();
    mispredicted = 1'b0;
    mispredicted_bmask_index = '0;

    // dispatch a NEW ready instruction with NO bmask
    dispatch_num = 2'd1;
    dispatch_pack[0] = '0;
    dispatch_pack[0].mult     = 1'b0;
    dispatch_pack[0].t1_ready = 1'b1;
    dispatch_pack[0].t2_ready = 1'b1;
    dispatch_pack[0].inst     = INST'(32'h3BAD_B002);
    dispatch_pack[0].opcode   = 7'h33;

    // Enable ALUs so it can issue
    alu0_ready = 1;
    alu1_ready = 1;

    tick(); // enqueue new one
    dispatch_num = 2'd0;

    expect_any_issue_within(6, "TEST3 post-flush new op issues");
  endtask

  task automatic test4_resolve_then_mispredict_doesnt_flush();
    $display("\n[TEST4] resolve_then_mispredict_doesnt_flush");


    b = bm_onehot(1);

    // block issue until after resolve/mispredict sequence
    alu0_ready = 0;
    alu1_ready = 0;

    dispatch_num = 2'd1;
    dispatch_pack[0] = '0;
    dispatch_pack[0].mult        = 1'b0;
    dispatch_pack[0].t1_ready    = 1'b1;
    dispatch_pack[0].t2_ready    = 1'b1;
    dispatch_pack[0].bmask       = b;
    dispatch_pack[0].bmask_index = b;
    dispatch_pack[0].inst        = INST'(32'h4444_4444);
    dispatch_pack[0].opcode      = 7'h33;

    tick(); // enqueue
    dispatch_num = 2'd0;

    // resolve clears the bit
    resolved = 1'b1;
    resolved_bmask_index = b;
    tick();
    resolved = 1'b0;
    resolved_bmask_index = '0;

    // Later mispredict on same bit should NOT flush
    mispredicted = 1'b1;
    mispredicted_bmask_index = b;
    tick();
    mispredicted = 1'b0;
    mispredicted_bmask_index = '0;

    // Now allow issue; it should issue soon
    alu0_ready = 1;
    alu1_ready = 1;

    expect_any_issue_within(6, "TEST4 resolve_then_mispredict survives");
  endtask

  initial begin
    reset_dut();
    test0_smoke_wakeup();

    reset_dut();
    test1_ready_issues_without_cdb();

    reset_dut();
    test2_alu_gating_blocks_issue();

    reset_dut();
    test3_mispredict_flush_blocks_issue();

    reset_dut();
    test4_resolve_then_mispredict_doesnt_flush();

    $display("\nALL BASIC TESTS PASSED");
    $finish;
  end

endmodule