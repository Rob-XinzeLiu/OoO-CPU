`include "sys_defs.svh"
`timescale 1ns/100ps

module testbench;

    logic               clock, reset, mispredicted;
    ALU_OPA_SELECT      [`N-1:0] opa_select;
    ALU_OPB_SELECT      [`N-1:0] opb_select;
    logic               [`N-1:0] has_dest, cond_branch, halt, is_branch, is_store, valid;
    X_C_PACKET          [`N-1:0] cdb;
    PRF_IDX             [`N-1:0] t_from_freelist;
    REG_IDX             [`N-1:0] rd, r1, r2;
    logic               [`MT_SIZE-1:0] snapshot_in;

    PRF_IDX             [`N-1:0] t1, t2, told;
    logic               [`N-1:0] t1_ready, t2_ready;
    logic               [`N-1:0][`MT_SIZE-1:0] snapshot_out;

    maptable dut (
        .clock(clock), .reset(reset), .mispredicted(mispredicted),
        .opa_select(opa_select), .opb_select(opb_select),
        .has_dest(has_dest), .cond_branch(cond_branch), .halt(halt),
        .cdb(cdb), .t_from_freelist(t_from_freelist),
        .rd(rd), .r1(r1), .r2(r2),
        .snapshot_in(snapshot_in), .is_branch(is_branch),
        .is_store(is_store), .valid(valid),
        .t1(t1), .t2(t2), .told(told),
        .t1_ready(t1_ready), .t2_ready(t2_ready),
        .snapshot_out(snapshot_out)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;
    int test_failed = 0;
    int test_num    = 0;

    task automatic reset_dut();
        clock = 0; reset = 1;
        mispredicted = 0;
        opa_select    = '{default: OPA_IS_RS1};
        opb_select    = '{default: OPB_IS_RS2};
        has_dest      = '0; cond_branch = '0; halt = '0;
        is_branch     = '0; is_store   = '0; valid = '0;
        cdb           = '{default: '0};
        t_from_freelist = '{default: '0};
        rd = '0; r1 = '0; r2 = '0;
        snapshot_in = '0;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
    endtask

    task automatic check(input string msg, input logic cond);
        if (!cond) begin
            $display("  FAIL [T%0d]: %s", test_num, msg);
            test_failed++;
        end
    endtask

    // Clear all dispatch inputs to idle
    task automatic idle();
        valid = '0; has_dest = '0; is_branch = '0; is_store = '0;
        cond_branch = '0; halt = '0;
        cdb = '{default: '0};
        rd = '0; r1 = '0; r2 = '0;
        t_from_freelist = '{default: '0};
        opa_select = '{default: OPA_IS_RS1};
        opb_select = '{default: OPB_IS_RS2};
    endtask

    // ---------------------------------------------------------------
    // T1: After reset, arch reg i maps to phys reg i, all p0-p31 ready
    // ---------------------------------------------------------------
    task automatic t1_reset_state();
        test_num = 1;
        $display("T1: Reset state");
        idle();
        // Read a few arch registers with no dispatch
        valid[0] = 1; r1[0] = 5'd1; r2[0] = 5'd3;
        #1;
        check("t1[0] should be p1 after reset", t1[0] == PRF_IDX'(1));
        check("t2[0] should be p3 after reset", t2[0] == PRF_IDX'(3));
        check("p1 ready",                        t1_ready[0]);
        check("p3 ready",                        t2_ready[0]);
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T2: Single rename — told = old mapping, new mapping after clock
    // ---------------------------------------------------------------
    task automatic t2_single_rename();
        test_num = 2;
        $display("T2: Single rename (rd=x5 → p33)");
        @(negedge clock);
        // Dispatch: rename x5 → p33
        valid[0] = 1; has_dest[0] = 1;
        rd[0] = 5'd5; r1[0] = 5'd1; r2[0] = 5'd2;
        t_from_freelist[0] = PRF_IDX'(33);
        opa_select[0] = OPA_IS_RS1; opb_select[0] = OPB_IS_RS2;
        #1;
        // told is combinational: old mt[5] = p5
        check("told[0] = old p5", told[0] == PRF_IDX'(5));
        @(negedge clock);  // posedge latches mt[5]=p33
        // Now read x5: should get p33, not ready
        idle();
        valid[0] = 1; r1[0] = 5'd5;
        #1;
        check("t1[0] after rename = p33", t1[0] == PRF_IDX'(33));
        check("p33 not ready",           !t1_ready[0]);
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T3: CDB broadcast makes p33 ready
    // ---------------------------------------------------------------
    task automatic t3_cdb_ready();
        test_num = 3;
        $display("T3: CDB broadcast p33 → ready");
        @(negedge clock);
        cdb[0].valid = 1'b1;
        cdb[0].complete_tag = PRF_IDX'(33);
        valid[0] = 1; r1[0] = 5'd5;  // read x5=p33
        #1;
        check("p33 ready after CDB", t1_ready[0]);
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T4: Dual dispatch WAW forwarding
    //     inst0: rd=x7 → p34
    //     inst1: rs1=x7 → must forward p34 (not old p7), not ready
    // ---------------------------------------------------------------
    task automatic t4_dual_waw();
        test_num = 4;
        $display("T4: Dual dispatch intra-cycle WAW forwarding");
        @(negedge clock);
        valid = 2'b11; has_dest = 2'b11;
        rd[0] = 5'd7;  r1[0] = 5'd1; r2[0] = 5'd2;
        rd[1] = 5'd8;  r1[1] = 5'd7; r2[1] = 5'd3;  // inst1 rs1=x7: should see p34
        t_from_freelist[0] = PRF_IDX'(34);
        t_from_freelist[1] = PRF_IDX'(35);
        opa_select = '{default: OPA_IS_RS1};
        opb_select = '{default: OPB_IS_RS2};
        #1;
        check("told[0] = old p7", told[0] == PRF_IDX'(7));
        // inst1 reads rs1=x7, should get forwarded p34 (not mt[7]=p7)
        check("t1[1] forwarded p34", t1[1] == PRF_IDX'(34));
        check("p34 not ready",       !t1_ready[1]);
        @(negedge clock);
        // After clock: mt[7]=p34, mt[8]=p35. Read x7.
        idle();
        valid[0] = 1; r1[0] = 5'd7;
        #1;
        check("x7 → p34 after rename", t1[0] == PRF_IDX'(34));
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T5: Dual dispatch WAW — inst1 told uses next_mt (not old mt)
    //     Both dispatch to same rd: inst0 rd=x9→p36, inst1 rd=x9→p37
    //     told[1] should see p36 (from inst0 this cycle), not p9
    // ---------------------------------------------------------------
    task automatic t5_dual_waw_told();
        test_num = 5;
        $display("T5: Dual WAW told[1] sees inst0 rename (next_mt)");
        @(negedge clock);
        valid = 2'b11; has_dest = 2'b11;
        rd[0] = 5'd9;  r1[0] = 5'd1; r2[0] = 5'd2;
        rd[1] = 5'd9;  r1[1] = 5'd1; r2[1] = 5'd2;  // same dest
        t_from_freelist[0] = PRF_IDX'(36);
        t_from_freelist[1] = PRF_IDX'(37);
        opa_select = '{default: OPA_IS_RS1};
        opb_select = '{default: OPB_IS_RS2};
        #1;
        check("told[0] = old p9",    told[0] == PRF_IDX'(9));
        check("told[1] = inst0 p36", told[1] == PRF_IDX'(36));  // next_mt after inst0
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T6: x0 is never renamed — told and t1 always p0
    // ---------------------------------------------------------------
    task automatic t6_x0_protection();
        test_num = 6;
        $display("T6: x0 never renamed");
        @(negedge clock);
        valid[0] = 1; has_dest[0] = 1;
        rd[0] = 5'd0; t_from_freelist[0] = PRF_IDX'(40);
        r1[0] = 5'd0; opa_select[0] = OPA_IS_RS1;
        #1;
        check("told[0] for x0 = p0", told[0] == PRF_IDX'(0));
        check("t1[0] for x0 = p0",   t1[0]   == PRF_IDX'(0));
        check("p0 always ready",       t1_ready[0]);
        @(negedge clock);
        // After clock: x0 must still map to p0 (has_dest on x0 must be ignored)
        idle();
        valid[0] = 1; r1[0] = 5'd0;
        #1;
        check("x0 still p0 after spurious rename", t1[0] == PRF_IDX'(0));
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T7: Branch snapshot and mispredict recovery
    //     1. Dispatch a branch, capture snapshot
    //     2. Rename x1 → p50 (changes mt)
    //     3. Mispredict → mt restored to snapshot (x1 back to p1 or p33)
    // ---------------------------------------------------------------
    task automatic t7_snapshot_recovery();
        test_num = 7;
        $display("T7: Branch snapshot + mispredict recovery");
        // Establish a known state: at this point x1→p1 (reset, not touched yet)
        // (Previous tests touched x5,x7,x8,x9 but not x1 after reset)
        @(negedge clock);
        // Dispatch a branch on slot 0 (no rename, just snapshot)
        valid[0] = 1; has_dest[0] = 0; is_branch[0] = 1;
        r1[0] = 5'd1; r2[0] = 5'd2;
        t_from_freelist[0] = '0;
        #1;
        // Snapshot is captured combinationally
        logic [`MT_SIZE-1:0] snap;
        snap = snapshot_out[0];
        @(negedge clock);
        idle();
        // Now rename x1 → p50
        @(negedge clock);
        valid[0] = 1; has_dest[0] = 1;
        rd[0] = 5'd1; t_from_freelist[0] = PRF_IDX'(50);
        opa_select[0] = OPA_IS_RS1;
        @(negedge clock);
        idle();
        // Confirm x1 is now p50
        valid[0] = 1; r1[0] = 5'd1;
        #1;
        check("x1 renamed to p50", t1[0] == PRF_IDX'(50));
        @(negedge clock);
        // Mispredict: restore from snapshot
        idle();
        mispredicted = 1; snapshot_in = snap;
        @(negedge clock);
        mispredicted = 0;
        // x1 should be restored to p1 (its value when the branch was dispatched)
        valid[0] = 1; r1[0] = 5'd1;
        #1;
        check("x1 restored to p1 after mispredict", t1[0] == PRF_IDX'(1));
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T8: CDB does NOT affect t_ready when register is renamed again
    //     (stale CDB tag should not set ready for a new allocation)
    // ---------------------------------------------------------------
    task automatic t8_stale_cdb();
        test_num = 8;
        $display("T8: Stale CDB tag does not corrupt new allocation");
        // Rename x10 → p38
        @(negedge clock);
        valid[0] = 1; has_dest[0] = 1;
        rd[0] = 5'd10; t_from_freelist[0] = PRF_IDX'(38);
        opa_select[0] = OPA_IS_RS1;
        @(negedge clock);
        idle();
        // Rename x10 again → p39 (p38 now stale)
        @(negedge clock);
        valid[0] = 1; has_dest[0] = 1;
        rd[0] = 5'd10; t_from_freelist[0] = PRF_IDX'(39);
        opa_select[0] = OPA_IS_RS1;
        // Simultaneously CDB broadcasts p38 (stale tag)
        cdb[0].valid = 1'b1; cdb[0].complete_tag = PRF_IDX'(38);
        @(negedge clock);
        idle();
        // x10 maps to p39, which should NOT be ready (CDB brought p38, not p39)
        valid[0] = 1; r1[0] = 5'd10;
        #1;
        check("x10 maps to p39", t1[0] == PRF_IDX'(39));
        // Note: p38 CDB should set prf_ready[38]=1, but p39 is still 0
        // This test verifies prf_ready[39] was not spuriously set
        // prf_ready[39] starts 0 (freshly allocated), CDB only set prf_ready[38]
        check("p39 still not ready (stale CDB for p38)", !t1_ready[0]);
        @(negedge clock);
        idle();
    endtask

    initial begin
        reset_dut();
        t1_reset_state();
        t2_single_rename();
        t3_cdb_ready();
        t4_dual_waw();
        t5_dual_waw_told();
        t6_x0_protection();
        t7_snapshot_recovery();
        t8_stale_cdb();
        if (test_failed == 0)
            $display("@@@ Passed");
        else
            $display("@@@ Failed (%0d checks failed)", test_failed);
        $finish;
    end

endmodule
