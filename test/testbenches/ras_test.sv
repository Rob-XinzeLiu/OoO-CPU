`include "sys_defs.svh"
`timescale 1ns/100ps

// Build JAL / JALR instruction words for the RAS testbench.
// JAL rd, imm   → j-type: opcode=7'b1101111, rd as given, imm encoded
// JALR rd, rs1, imm → i-type: opcode=7'b1100111, funct3=0
`define MAKE_JAL(rd_reg)  {20'b0, (rd_reg), 7'b110_1111}    // imm=0, any non-zero rd
`define MAKE_JALR(rd_reg, rs1_reg)  {12'b0, (rs1_reg), 3'b000, (rd_reg), 7'b110_0111}
`define MAKE_NOP          32'h0000_0013  // addi x0, x0, 0

module testbench;

    logic       clock, reset, mispredict;
    INST        [1:0] inst;
    ADDR        [1:0] npc;
    logic       [1:0] input_valid;
    logic       [1:0] recovered_head;
    logic       [2:0] recovered_count;

    ADDR        [1:0] return_addr;
    logic       [1:0] valid_addr;
    logic       [1:0] current_head;
    logic       [2:0] current_count;

    ras dut (
        .clock(clock), .reset(reset), .mispredict(mispredict),
        .inst(inst), .npc(npc), .input_valid(input_valid),
        .recovered_head(recovered_head), .recovered_count(recovered_count),
        .return_addr(return_addr), .valid_addr(valid_addr),
        .current_head(current_head), .current_count(current_count)
    );

    always #(`CLOCK_PERIOD/2.0) clock = ~clock;
    int test_failed = 0;
    int test_num    = 0;

    task automatic reset_dut();
        clock = 0; reset = 1; mispredict = 0;
        inst        = '{default: `NOP};
        npc         = '{default: '0};
        input_valid = '0;
        recovered_head = '0; recovered_count = '0;
        @(negedge clock); reset = 0;
        @(negedge clock);
    endtask

    task automatic check(input string msg, input logic cond);
        if (!cond) begin
            $display("  FAIL [T%0d]: %s", test_num, msg);
            test_failed++;
        end
    endtask

    task automatic idle();
        inst        = '{default: `NOP};
        npc         = '{default: '0};
        input_valid = '0;
        mispredict  = 0;
    endtask

    // ---------------------------------------------------------------
    // T1: After reset — stack empty, no valid return addresses
    // ---------------------------------------------------------------
    task automatic t1_reset();
        test_num = 1;
        $display("T1: Reset — stack empty");
        #1;
        check("count=0 after reset", current_count == 3'd0);
        check("valid_addr=0 after reset", valid_addr == 2'b00);
    endtask

    // ---------------------------------------------------------------
    // T2: JAL x1 (link reg) — push NPC onto stack
    // ---------------------------------------------------------------
    task automatic t2_jal_push();
        test_num = 2;
        $display("T2: JAL x1 → push return addr");
        @(negedge clock);
        idle();
        input_valid[0] = 1;
        inst[0]        = `MAKE_JAL(5'd1);   // JAL x1, 0 (rd=x1=ra)
        npc[0]         = 32'h0000_1000;     // pretend PC+4 = 0x1000
        @(negedge clock);
        idle();
        #1;
        check("count=1 after JAL", current_count == 3'd1);
    endtask

    // ---------------------------------------------------------------
    // T3: JALR x0, x1, 0 (ret) — pop return address
    // ---------------------------------------------------------------
    task automatic t3_jalr_pop();
        test_num = 3;
        $display("T3: JALR x0, x1, 0 (ret) → pop");
        @(negedge clock);
        idle();
        input_valid[0] = 1;
        inst[0]        = `MAKE_JALR(5'd0, 5'd1);  // rd=x0 (no link), rs1=x1 (link) → pop
        npc[0]         = 32'hDEAD;
        #1;
        // Before clock: pop output is combinational
        check("valid_addr[0] on pop",        valid_addr[0]);
        check("return_addr[0] = 0x1000",     return_addr[0] == 32'h0000_1000);
        @(negedge clock);
        idle();
        #1;
        check("count=0 after ret", current_count == 3'd0);
    endtask

    // ---------------------------------------------------------------
    // T4: Nested calls — push, push, pop, pop (LIFO order)
    // ---------------------------------------------------------------
    task automatic t4_nested_calls();
        test_num = 4;
        $display("T4: Nested calls — push A, push B, ret (get B), ret (get A)");
        // Call A: push 0x2000
        @(negedge clock);
        idle();
        input_valid[0] = 1;
        inst[0] = `MAKE_JAL(5'd1); npc[0] = 32'h0000_2000;
        @(negedge clock);
        // Call B: push 0x3000
        idle();
        input_valid[0] = 1;
        inst[0] = `MAKE_JAL(5'd1); npc[0] = 32'h0000_3000;
        @(negedge clock);
        idle();
        #1;
        check("count=2 after two calls", current_count == 3'd2);
        // Return B: should get 0x3000
        @(negedge clock);
        idle();
        input_valid[0] = 1;
        inst[0] = `MAKE_JALR(5'd0, 5'd1);  // ret
        #1;
        check("ret B: valid",         valid_addr[0]);
        check("ret B: addr = 0x3000", return_addr[0] == 32'h0000_3000);
        @(negedge clock);
        idle();
        #1;
        check("count=1 after first ret", current_count == 3'd1);
        // Return A: should get 0x2000
        @(negedge clock);
        idle();
        input_valid[0] = 1;
        inst[0] = `MAKE_JALR(5'd0, 5'd1);  // ret
        #1;
        check("ret A: valid",         valid_addr[0]);
        check("ret A: addr = 0x2000", return_addr[0] == 32'h0000_2000);
        @(negedge clock);
        idle();
        #1;
        check("count=0 after both rets", current_count == 3'd0);
    endtask

    // ---------------------------------------------------------------
    // T5: Dual dispatch — slot0 pushes, slot1 pops (same cycle)
    //     Stack before: empty. slot0 = JAL x1 (push 0x4000)
    //     slot1 = JALR x0, x1 (ret) — should see slot0's pushed addr
    // ---------------------------------------------------------------
    task automatic t5_dual_push_pop();
        test_num = 5;
        $display("T5: Dual dispatch: slot0 push, slot1 pop same cycle");
        @(negedge clock);
        idle();
        // slot0: JAL x1 (push 0x4000)
        input_valid[0] = 1;
        inst[0] = `MAKE_JAL(5'd1); npc[0] = 32'h0000_4000;
        // slot1: JALR x0, x1 (ret) — pops from slot0's push (not from empty stack)
        input_valid[1] = 1;
        inst[1] = `MAKE_JALR(5'd0, 5'd1); npc[1] = 32'h0000_5000;
        #1;
        // slot1 pops: with slot0 pushing 0x4000, slot1 should see 0x4000
        check("slot1 valid_addr on same-cycle push/pop", valid_addr[1]);
        check("slot1 return_addr = 0x4000 (from slot0 push)", return_addr[1] == 32'h0000_4000);
        @(negedge clock);
        idle();
        #1;
        check("count=0 after dual push+pop", current_count == 3'd0);
    endtask

    // ---------------------------------------------------------------
    // T6: Dual dispatch — both slots push (two calls in one cycle)
    // ---------------------------------------------------------------
    task automatic t6_dual_push();
        test_num = 6;
        $display("T6: Dual dispatch: both slots push");
        @(negedge clock);
        idle();
        input_valid = 2'b11;
        inst[0] = `MAKE_JAL(5'd1); npc[0] = 32'h0000_6000;
        inst[1] = `MAKE_JAL(5'd1); npc[1] = 32'h0000_7000;
        @(negedge clock);
        idle();
        #1;
        check("count=2 after dual push", current_count == 3'd2);
        // Ret twice to verify LIFO
        @(negedge clock);
        input_valid[0] = 1; inst[0] = `MAKE_JALR(5'd0, 5'd1);
        #1;
        check("pop 0x7000 first (LIFO)", return_addr[0] == 32'h0000_7000);
        @(negedge clock);
        idle();
        input_valid[0] = 1; inst[0] = `MAKE_JALR(5'd0, 5'd1);
        #1;
        check("pop 0x6000 second (LIFO)", return_addr[0] == 32'h0000_6000);
        @(negedge clock);
        idle();
        #1;
        check("count=0 after two rets", current_count == 3'd0);
    endtask

    // ---------------------------------------------------------------
    // T7: Stack overflow — push more than RAS_SIZE=4
    //     count saturates at 4, oldest entry overwritten (circular)
    // ---------------------------------------------------------------
    task automatic t7_overflow();
        test_num = 7;
        $display("T7: Stack overflow — count saturates at RAS_SIZE=4");
        // Push 5 entries; count should cap at 4
        for (int i = 0; i < 5; i++) begin
            @(negedge clock);
            idle();
            input_valid[0] = 1;
            inst[0] = `MAKE_JAL(5'd1);
            npc[0] = ADDR'(32'hA000 + i * 4);
        end
        @(negedge clock);
        idle();
        #1;
        check("count = 4 after 5 pushes (saturation)", current_count == 3'd4);
        // Clean up: mispredict to restore empty state
        mispredict = 1; recovered_head = '0; recovered_count = '0;
        @(negedge clock);
        idle();
        #1;
        check("count = 0 after mispredict recovery", current_count == 3'd0);
    endtask

    // ---------------------------------------------------------------
    // T8: Mispredict recovery restores head and count
    // ---------------------------------------------------------------
    task automatic t8_mispredict_recovery();
        test_num = 8;
        $display("T8: Mispredict recovery — head/count restored");
        // Push two entries
        @(negedge clock);
        idle();
        input_valid[0] = 1; inst[0] = `MAKE_JAL(5'd1); npc[0] = 32'hB000;
        @(negedge clock);
        idle();
        input_valid[0] = 1; inst[0] = `MAKE_JAL(5'd1); npc[0] = 32'hC000;
        @(negedge clock);
        idle();
        #1;
        check("count=2 before recovery", current_count == 3'd2);
        // Save head/count as checkpoint (pretend we saved state when count was 1)
        // Recover to count=1, head at the position before last push
        // head after 1 push from empty = 1 (circular, head tracks next write pos)
        @(negedge clock);
        mispredict = 1;
        recovered_count = 3'd1;
        recovered_head  = 2'd1;  // 1 push from reset → head=1
        @(negedge clock);
        idle();
        #1;
        check("count restored to 1", current_count == 3'd1);
        // Ret: should get 0xB000 (the one entry that was valid at checkpoint)
        @(negedge clock);
        input_valid[0] = 1; inst[0] = `MAKE_JALR(5'd0, 5'd1);
        #1;
        check("recovered ret addr = 0xB000", return_addr[0] == 32'hB000);
        @(negedge clock);
        idle();
    endtask

    // ---------------------------------------------------------------
    // T9: Pop on empty stack — valid_addr should be 0
    // ---------------------------------------------------------------
    task automatic t9_pop_empty();
        test_num = 9;
        $display("T9: Pop on empty stack — valid_addr=0");
        @(negedge clock);
        idle();
        #1;
        check("count=0 before test", current_count == 3'd0);
        input_valid[0] = 1;
        inst[0] = `MAKE_JALR(5'd0, 5'd1);  // ret with empty stack
        #1;
        check("valid_addr=0 on empty pop", !valid_addr[0]);
        @(negedge clock);
        idle();
    endtask

    initial begin
        reset_dut();
        t1_reset();
        t2_jal_push();
        t3_jalr_pop();
        t4_nested_calls();
        t5_dual_push_pop();
        t6_dual_push();
        t7_overflow();
        t8_mispredict_recovery();
        t9_pop_empty();
        if (test_failed == 0)
            $display("@@@ Passed");
        else
            $display("@@@ Failed (%0d checks failed)", test_failed);
        $finish;
    end

endmodule
