`timescale 1ns/1ps
`include "sys_defs.svh"

module freelist_tb;

  localparam int N = `N;

  logic clock;
  logic reset;

  // scalar counts 0..2
  logic [1:0] retire_num;
  logic [1:0] dispatch_num;

  ROB_IDX Branch_stack_H;
  logic [$clog2(`ROB_SZ):0] Branch_stack_C;

  logic dispatch_valid;
  logic retire_valid;
  logic cond_branch [N-1:0];
  logic mispredicted;
  ROB_IDX restore_head;

  PRF_IDX t [N-1:0];
  logic full;
  ROB_IDX BS_head [N-1:0];
  // TB-side "branch stack" snapshot
  ROB_IDX saved_head0;
  logic [$clog2(`ROB_SZ):0] saved_cnt0;
  


  // -----------------------
  // DUT
  // -----------------------
  freelist dut (
    .clock(clock),
    .reset(reset),
    .retire_num(retire_num),
    .dispatch_num(dispatch_num),
    .Branch_stack_H(Branch_stack_H),
    .Branch_stack_C(Branch_stack_C),
    .dispatch_valid(dispatch_valid),
    .retire_valid(retire_valid),
    .cond_branch(cond_branch),
    .mispredicted(mispredicted),
    .t(t),
    .full(full),
    .BS_head(BS_head)
  );

  // -----------------------
  // Clock gen
  // -----------------------
  initial clock = 0;
  always #5 clock = ~clock;

  // -----------------------
  // Helpers
  // -----------------------
  task automatic clear_inputs();
    begin
      retire_num      = 0;
      dispatch_num    = 0;
      Branch_stack_H  = '0;
      Branch_stack_C  = '0;
      dispatch_valid  = 0;
      retire_valid    = 0;
      mispredicted    = 0;
      for (int i=0; i<N; i++) cond_branch[i] = 0;
    end
  endtask

  // Only advance to posedge (no hidden negedge)
  task automatic step_posedge();
    begin
      @(posedge clock);
      #1;
    end
  endtask

  // Drive at negedge, let always_comb settle
  task automatic drive_and_settle();
    begin
      @(negedge clock);
      #0; #0;
      #1;
    end
  endtask

  task automatic expect_tag(input int lane, input int exp);
    begin
      if (t[lane] !== PRF_IDX'(exp)) begin
        $display("FAIL @%0t: lane %0d tag exp=%0d got=%0d (head=%0d tail=%0d cnt=%0d full=%0b)",
                 $time, lane, exp, t[lane], dut.head, dut.tail, dut.cnt, full);
        $fatal(1);
      end
    end
  endtask

  task automatic expect_zero(input int lane);
    begin
      if (t[lane] !== PRF_IDX'('0)) begin
        $display("FAIL @%0t: lane %0d exp=0 got=%0d (head=%0d tail=%0d cnt=%0d full=%0b)",
                 $time, lane, t[lane], dut.head, dut.tail, dut.cnt, full);
        $fatal(1);
      end
    end
  endtask

  // ---- NEW: expect cnt / tail helpers ----
  task automatic expect_cnt(input int exp);
    begin
      if (dut.cnt !== exp) begin
        $display("FAIL @%0t: cnt exp=%0d got=%0d (head=%0d tail=%0d full=%0b)",
                 $time, exp, dut.cnt, dut.head, dut.tail, full);
        $fatal(1);
      end
    end
  endtask

  task automatic expect_tail(input int exp);
    begin
      if (dut.tail !== exp) begin
        $display("FAIL @%0t: tail exp=%0d got=%0d (head=%0d cnt=%0d full=%0b)",
                 $time, exp, dut.tail, dut.head, dut.cnt, full);
        $fatal(1);
      end
    end
  endtask

  // -----------------------
  // Monitors / Debug
  // -----------------------
  task automatic mon_posedge(string tag = "");
    $display("MON %s @%0t posedge: rst=%0b dv=%0b dn=%0d rv=%0b rn=%0d mis=%0b BH=%0d | head=%0d tail=%0d cnt=%0d full=%0b | t0=%0d t1=%0d | BS0=%0d BS1=%0d",
             tag, $time, reset,
             dispatch_valid, dispatch_num,
             retire_valid, retire_num,
             mispredicted, Branch_stack_H,
             dut.head, dut.tail, dut.cnt, full,
             t[0], (N>1 ? t[1] : PRF_IDX'('0)),
             BS_head[0], (N>1 ? BS_head[1] : ROB_IDX'('0)));
  endtask

  // -----------------------
  // Main test
  // -----------------------
  initial begin
    int pre_cnt;
    int pre_tail;
    int safety;
    $display("=== freelist_tb starting ===");
    clear_inputs();

    // ----------------
    // Reset sequence
    // ----------------
    reset = 1;
    step_posedge(); mon_posedge("reset1");
    step_posedge(); mon_posedge("reset2");

    @(negedge clock);
    reset = 0;
    #0; #0; #1;
    step_posedge(); mon_posedge("out_of_reset");

    // If your design intends cnt == FLIST_SZ (or ROB_SZ) after reset, enforce it:
    // (adjust expected value if you rename FLIST_SZ)
    expect_cnt(`ROB_SZ);

    // ------------------------------------------------------------
    // Test 1: Dispatch 1 allocation after reset
    // ------------------------------------------------------------
    drive_and_settle();
    dispatch_valid = 1;
    dispatch_num   = 2'd1;
    #0; #0; #1;

    $display("DBG T1 pre-pos (negedge): head=%0d tail=%0d cnt=%0d full=%0b dn=%0d t0=%0d t1=%0d",
             dut.head, dut.tail, dut.cnt, full, dispatch_num, t[0], t[1]);

    expect_tag(0, `PHYS_REG_SZ_P6 + 0);
    if (N > 1) expect_zero(1);

    step_posedge(); mon_posedge("T1_posedge");
    clear_inputs();

    // ------------------------------------------------------------
    // Test 2: Dispatch 2 allocations next cycle
    // ------------------------------------------------------------
    drive_and_settle();
    dispatch_valid = 1;
    dispatch_num   = 2'd2;
    #0; #0; #1;

    $display("DBG T2 pre-pos (negedge): head=%0d tail=%0d cnt=%0d full=%0b dn=%0d t0=%0d t1=%0d",
             dut.head, dut.tail, dut.cnt, full, dispatch_num, t[0], t[1]);

    expect_tag(0, `PHYS_REG_SZ_P6 + 1);
    if (N > 1) expect_tag(1, `PHYS_REG_SZ_P6 + 2);

    step_posedge(); mon_posedge("T2_posedge");
    clear_inputs();

    // ------------------------------------------------------------
    // NEW Test 2.5: Retire 1 and check cnt/tail changes
    // ------------------------------------------------------------
    // Save pre-retire state
    pre_cnt  = dut.cnt;
    pre_tail = dut.tail;

    drive_and_settle();
    retire_valid = 1;
    retire_num   = 2'd1;
    #0; #0; #1;

    $display("DBG R1 pre-pos (negedge): head=%0d tail=%0d cnt=%0d rn=%0d",
             dut.head, dut.tail, dut.cnt, retire_num);

    step_posedge(); mon_posedge("R1_posedge");

    // Expect +1 free reg (cnt increases)
    expect_cnt(pre_cnt + 1);

    // Tail should advance by 1 in FIFO enqueue model.
    // If you implement wrap: expected = (pre_tail + 1) % `ROB_SZ
    // If you haven't wrapped yet, this may fail near end; that's fine.
    expect_tail((pre_tail + 1) % `ROB_SZ);

    clear_inputs();

    // ------------------------------------------------------------
    // NEW Test 2.6: Retire 2 and check cnt/tail changes
    // ------------------------------------------------------------
    pre_cnt  = dut.cnt;
    pre_tail = dut.tail;

    drive_and_settle();
    retire_valid = 1;
    retire_num   = 2'd2;
    #0; #0; #1;

    $display("DBG R2 pre-pos (negedge): head=%0d tail=%0d cnt=%0d rn=%0d",
             dut.head, dut.tail, dut.cnt, retire_num);

    step_posedge(); mon_posedge("R2_posedge");

    expect_cnt(pre_cnt + 2);
    expect_tail((pre_tail + 2) % `ROB_SZ);

    clear_inputs();

    // ------------------------------------------------------------
    // NEW Test 2.7: Retire makes dispatch possible again when empty
    // ------------------------------------------------------------
    // Drain freelist by dispatching until full/empty indicates no regs.
    // This assumes your "full" signal actually means EMPTY (cnt==0).
    // If you later rename it, update this.
    safety = 0;
    while (!full && safety < 50) begin
      drive_and_settle();
      dispatch_valid = 1;
      dispatch_num   = 2'd2; // drain faster
      #0; #0; #1;
      step_posedge(); mon_posedge("drain");
      clear_inputs();
      safety++;
    end

    if (!full) begin
      $display("FAIL: did not reach empty/full within safety limit (cnt=%0d full=%0b)", dut.cnt, full);
      $fatal(1);
    end
    $display("DBG drained: head=%0d tail=%0d cnt=%0d full=%0b", dut.head, dut.tail, dut.cnt, full);

    // Now retire 2 -> should un-empty and allow allocation
    drive_and_settle();
    retire_valid = 1;
    retire_num   = 2'd2;
    #0; #0; #1;
    step_posedge(); mon_posedge("retire_to_unempty");
    clear_inputs();

    if (full) begin
      $display("FAIL: expected not-empty after retire, but full/empty still asserted (cnt=%0d)", dut.cnt);
      $fatal(1);
    end

    // Allocate 1 and ensure t0 is nonzero now
    drive_and_settle();
    dispatch_valid = 1;
    dispatch_num   = 2'd1;
    #0; #0; #1;

    if (t[0] === PRF_IDX'('0)) begin
      $display("FAIL: expected allocation after retire, but t0 is 0 (head=%0d tail=%0d cnt=%0d)",
               dut.head, dut.tail, dut.cnt);
      $fatal(1);
    end
    step_posedge(); mon_posedge("alloc_after_retire");
    clear_inputs();

    // ------------------------------------------------------------
    // Test 3: Branch snapshot output (no dispatch_valid asserted)
    // ------------------------------------------------------------
    // ------------------------------------------------------------
    // Test 3: Branch snapshot output (no dispatch_valid asserted)
    // ------------------------------------------------------------
    drive_and_settle();
    clear_inputs();
    cond_branch[0] = 1;
    #0; #0; #1;

    // TB-side snapshot: take BOTH from DUT state at the same time
    saved_head0 = dut.head;
    saved_cnt0  = dut.cnt;

    $display("DBG T3 snapshot (negedge): head=%0d tail=%0d cnt=%0d | saved_head0=%0d saved_cnt0=%0d | BS0=%0d BS1=%0d",
             dut.head, dut.tail, dut.cnt, saved_head0, saved_cnt0, BS_head[0], BS_head[1]);

    step_posedge(); mon_posedge("T3_posedge");
    clear_inputs();

    // ------------------------------------------------------------
    // Test 4: Mispredict restore + allocate
    // ------------------------------------------------------------
    restore_head = saved_head0;

    drive_and_settle();
    clear_inputs();
    Branch_stack_H = restore_head;
    Branch_stack_C = saved_cnt0;   // <-- THIS is the key fix
    mispredicted   = 1;
    #0; #0; #1;


    $display("DBG pre-restore (negedge): set BH=%0d mis=%0b | head=%0d tail=%0d cnt=%0d",
             Branch_stack_H, mispredicted, dut.head, dut.tail, dut.cnt);

    step_posedge(); mon_posedge("restore_posedge");
    clear_inputs();

    drive_and_settle();
    clear_inputs();
    #0; #0; #1;
    step_posedge(); mon_posedge("idle_after_restore");

    drive_and_settle();
    clear_inputs();
    dispatch_valid = 1;
    dispatch_num   = 2'd1;
    #0; #0; #1;

    $display("DBG alloc-check (negedge): head=%0d tail=%0d cnt=%0d t0=%0d",
             dut.head, dut.tail, dut.cnt, t[0]);

    if (t[0] === PRF_IDX'('0)) begin
      $display("FAIL: expected allocation after restore, but t0 is 0 (head=%0d tail=%0d cnt=%0d)",
               dut.head, dut.tail, dut.cnt);
      $fatal(1);
    end

    step_posedge(); mon_posedge("alloc_after_restore_posedge");
    clear_inputs();

    $display("=== freelist_tb PASSED ===");
    $finish;
  end

endmodule