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

  ETB_TAG_PACKET                early_tag_bus   [`N-1:0];
  logic                         cdb_gnt_alu     [`N-1:0];
  logic                         cdb_req_alu     [`N-1:0];
  D_S_PACKET                    issue_pack      [`N-1:0];

  logic [1:0] dbg_issue_count;

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
    .early_tag_bus(early_tag_bus),
    .cdb_gnt_alu(cdb_gnt_alu),
    .cdb_req_alu(cdb_req_alu),
    .issue_pack(issue_pack),
    .empty_entries_num(empty_entries_num),
    .dbg_issue_count(dbg_issue_count)
  );

  initial clock = 0;
  always #5 clock = ~clock;

  task automatic tick();
    @(posedge clock);
  endtask

  task automatic reset_dut();
    reset = 1;
    mispredicted = 0;
    mispredicted_bmask_index = '0;
    resolved = 0;
    resolved_bmask_index = '0;
    dispatch_num = 2'd0;
    cdb_gnt_alu = '{default: '0};
    early_tag_bus = '{default: '0};


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
    return dbg_issue_count;
  endfunction

  // Wait up to max_cycles for ANY issue to happen.
  // task automatic expect_any_issue_within(input int max_cycles, input string tag);
  //   bit ok;
  //   ok = 0;
  //   for (int i = 0; i < max_cycles; i++) begin
  //     tick();
  //     if (issued_count() > 0) begin
  //       ok = 1;
  //       break;
  //     end
  //   end
  //   if (!ok) begin
  //     $error("FAIL %s: expected some issue but saw none within %0d cycles", tag, max_cycles);
  //     $finish;
  //   end
  //   $display("PASS %s: issued_count=%0d", tag, issued_count());
  // endtask

  // Wait up to max_cycles for NO issue to happen (issued_count must stay 0).
  // task automatic expect_no_issue_for(input int max_cycles, input string tag);
  //   for (int i = 0; i < max_cycles; i++) begin
  //     tick();
  //     if (issued_count() > 0) begin
  //       $error("FAIL %s: expected no issue but saw issued_count=%0d", tag, issued_count());
  //       $finish;
  //     end
  //   end
  //   $display("PASS %s: no issue for %0d cycles", tag, max_cycles);
  // endtask

  function automatic B_MASK bm_onehot(int idx);
    B_MASK tmp;
    tmp = '0;
    tmp[idx] = 1'b1;
    return tmp;
  endfunction

  task automatic display_rs_table(string tag);
    $display("\n================ RS TABLE: %s (t=%0t) ================", tag, $time);
    $display("empty_entries_num=%0d  dbg_issue_count=%0d", empty_entries_num, dut.dbg_issue_count);
    $display(" idx | busy | mult |  t1  r1 |  t2  r2 | bmask | rob |    PC");
    $display("-----+------+------+- ----- --+- ----- --+------+-----+----------");

    for (int i = 0; i < `RS_SZ; i++) begin
      $display("%4d |  %0d   |  %0d   | %4d  %0d | %4d  %0d | %4b | %3d | %08h",
        i,
        dut.next_rs_entry[i].busy,
        dut.next_rs_entry[i].mult,
        dut.next_rs_entry[i].t1,
        dut.next_rs_entry[i].t1_ready,
        dut.next_rs_entry[i].t2,
        dut.next_rs_entry[i].t2_ready,
        dut.next_rs_entry[i].bmask,
        dut.next_rs_entry[i].rob_index,
        dut.next_rs_entry[i].PC
      );
    end

    $display("============================================================\n");
endtask

  // ==============================================================
  // TESTS (all "basic", and none require matching a specific INST)
  // ==============================================================

    task automatic test0_smoke_wakeup();
        $display("\n[TEST0] smoke_wakeup");

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
  
        

        cdb_gnt_alu[0] = 'b1;
        early_tag_bus[0].valid = 'b1;
        early_tag_bus[0].tag =  PRF_IDX'(12);
        tick();
        display_rs_table("after enqueue");

        //display_rs_table("after enqueue");
        assert(dbg_issue_count == 'd1 );
        assert(issue_pack[0].t1 == PRF_IDX'(12));
        assert (issue_pack[0].t2 == PRF_IDX'(13));
        tick(); // wakeup registers
        cdb[0] = '0;
        // give a small window for issue (covers the 1-cycle wakeup latency)
        //expect_any_issue_within(4, "TEST0 smoke_wakeup");
    endtask

  task test1_1mult_1alu();
        dispatch_num = 2'd2;

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

        dispatch_pack[1] = '0;
        dispatch_pack[1].mult     = 1'b0;
        dispatch_pack[1].t1       = PRF_IDX'(14);
        dispatch_pack[1].t2       = PRF_IDX'(15);
        dispatch_pack[1].t1_ready = 1'b1;
        dispatch_pack[1].t2_ready = 1'b0;
        dispatch_pack[1].PC       = ADDR'(32'h1000);
        dispatch_pack[1].NPC      = ADDR'(32'h1008);
        dispatch_pack[1].inst     = INST'(32'hDEADBEEF);
        dispatch_pack[1].opcode   = 7'h33;
        rob_index[1]              = ROB_IDX'(4);

        tick();
        display_rs_table("after dispatch 2 alu");

        dispatch_num = 2'd1;
        dispatch_pack[0] = '0;
        dispatch_pack[0].mult     = 1'b1;
        dispatch_pack[0].t1       = PRF_IDX'(16);
        dispatch_pack[0].t2       = PRF_IDX'(17);
        dispatch_pack[0].t1_ready = 1'b1;
        dispatch_pack[0].t2_ready = 1'b1;
        dispatch_pack[0].PC       = ADDR'(32'h1000);
        dispatch_pack[0].NPC      = ADDR'(32'h1004);
        dispatch_pack[0].inst     = INST'(32'hDEADBEEF);
        dispatch_pack[0].opcode   = 7'h33;
        rob_index[0]              = ROB_IDX'(3);

        cdb_gnt_alu[0] = 'b1;
        cdb_gnt_alu[1] = 'b1;
        early_tag_bus[0].valid = 'b1;
        early_tag_bus[0].tag =  PRF_IDX'(12);
        early_tag_bus[1].valid = 'b1;
        early_tag_bus[1].tag =  PRF_IDX'(15);
        tick();
        dispatch_num = 'd0;
        early_tag_bus[0].valid = 'd0;
        early_tag_bus[1].valid = 'd0;
        cdb_gnt_alu[0] = 'd0;
        cdb_gnt_alu[1] = 'd0;

        display_rs_table("after enqueue");
        assert (issue_pack[0].mult);
        assert (!issue_pack[1].mult);
  endtask

  task test2_2alu();
        dispatch_num = 2'd2;

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

        dispatch_pack[1] = '0;
        dispatch_pack[1].mult     = 1'b0;
        dispatch_pack[1].t1       = PRF_IDX'(14);
        dispatch_pack[1].t2       = PRF_IDX'(15);
        dispatch_pack[1].t1_ready = 1'b1;
        dispatch_pack[1].t2_ready = 1'b0;
        dispatch_pack[1].PC       = ADDR'(32'h1000);
        dispatch_pack[1].NPC      = ADDR'(32'h1008);
        dispatch_pack[1].inst     = INST'(32'hDEADBEEF);
        dispatch_pack[1].opcode   = 7'h33;
        rob_index[1]              = ROB_IDX'(4);

        tick();
        display_rs_table("after dispatch 2 alu");
        dispatch_num = 'd0;
        cdb_gnt_alu[0] = 'b1;
        cdb_gnt_alu[1] = 'b1;
        early_tag_bus[0].valid = 'b1;
        early_tag_bus[0].tag =  PRF_IDX'(12);
        early_tag_bus[1].valid = 'b1;
        early_tag_bus[1].tag =  PRF_IDX'(15);
        tick();
        early_tag_bus[0].valid = 'd0;
        early_tag_bus[1].valid = 'd0;
        cdb_gnt_alu[0] = 'd0;
        cdb_gnt_alu[1] = 'd0;

        display_rs_table("after enqueue");
        assert (!issue_pack[0].mult);
        assert (!issue_pack[1].mult);
  endtask
    
    

  initial begin
    reset_dut();
    test0_smoke_wakeup();
    #100;

    reset_dut();
    test1_1mult_1alu();
    #100;

    reset_dut();
    test2_2alu();
    

    $display("\nALL BASIC TESTS PASSED");
    $finish;
  end

endmodule