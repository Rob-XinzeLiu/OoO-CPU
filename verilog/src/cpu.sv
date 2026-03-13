/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  cpu.sv                                              //
//                                                                     //
//  Description :  Top-level module of the verisimple processor;       //
//                 This instantiates and connects the 5 stages of the  //
//                 Verisimple pipeline together.                       //
//                 This is a reference file. You will have to          //
//                 significantly modify this for your processor!       //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module cpu (
    input clock, // System clock
    input reset, // System reset

    // ----------------------------------------------------------------
    //  Step 3/4: testbench drives PC and raw instruction data directly
    // ----------------------------------------------------------------
    input  ADDR         tb_PC,          // current fetch address from testbench
    input  MEM_BLOCK    tb_imem_data,   // 64-bit memory line for that address
 
    // ----------------------------------------------------------------
    //  Step 5: tell the testbench how many instructions we accepted
    // ----------------------------------------------------------------
    output logic [1:0]  fetch_accepted,
 
    // ----------------------------------------------------------------
    //  Retire / writeback (step 7)
    // ----------------------------------------------------------------
    output RETIRE_PACKET [`N-1:0] committed_insts,
 
    // ----------------------------------------------------------------
    //  Step 8: branch redirect back to testbench
    // ----------------------------------------------------------------
    output logic        branch_taken,
    output ADDR         branch_target,
    output logic        mispredicted
    // input MEM_TAG   mem2proc_transaction_tag, // Memory tag for current transaction
    // input MEM_BLOCK mem2proc_data,            // Data coming back from memory
    // input MEM_TAG   mem2proc_data_tag,        // Tag for which transaction data is for

    // output MEM_COMMAND proc2mem_command, // Command sent to memory
    // output ADDR        proc2mem_addr,    // Address sent to memory
    // output MEM_BLOCK   proc2mem_data,    // Data sent to memory
    // output MEM_SIZE    proc2mem_size,    // Data size sent to memory

    // // Note: these are assigned at the very bottom of the module
    // output RETIRE_PACKET [`N-1:0] committed_insts,

    // // Debug outputs: these signals are solely used for debugging in testbenches
    // // You should definitely change these for the final project
    // output ADDR  if_NPC_dbg,
    // output DATA  if_inst_dbg,
    // output logic if_valid_dbg,
    // output ADDR  if_id_NPC_dbg,
    // output DATA  if_id_inst_dbg,
    // output logic if_id_valid_dbg,
    // output ADDR  id_ex_NPC_dbg,
    // output DATA  id_ex_inst_dbg,
    // output logic id_ex_valid_dbg,
    // output ADDR  ex_mem_NPC_dbg,
    // output DATA  ex_mem_inst_dbg,
    // output logic ex_mem_valid_dbg,
    // output ADDR  mem_wb_NPC_dbg,
    // output DATA  mem_wb_inst_dbg,
    // output logic mem_wb_valid_dbg
);
    logic   global_mispredict;
    logic   global_resolve;
    B_MASK  global_mispredict_index;
    B_MASK  global_resolve_index;
    B_MASK  global_mispredict_bmask;
    
    //////////////////////////////////////////////////
    //                                              //
    //                Pipeline Wires                //
    //                                              //
    //////////////////////////////////////////////////

    // Pipeline register enables
    logic if_id_enable, id_ex_enable, ex_mem_enable, mem_wb_enable;

    // From IF stage to memory
    MEM_COMMAND Imem_command; // Command sent to memory

    // Outputs from IF-Stage and IF/ID Pipeline Register
    F_D_PACKET  f_pack [`N-1:0];
    F_D_PACKET  f_pack_reg [`N-1:0];
    logic [1:0] dispatch_num_reg ;
 
    // Outputs from Fetch buffer
    F_D_PACKET  f_d_pack[`N-1:0];
    logic [1:0] can_fetch_num;

    // Outputs from Dispatch stage
    D_S_PACKET  dispatch_out_pack [`N-1:0];
    logic           dispatch_valid [`N-1:0];
    logic           branch_encountered [`N-1:0];
    B_MASK          branch_index [`N-1:0];
    logic [`N-1:0][`MT_SIZE-1:0] maptable_snapshot_out ;
    ADDR            pc_snapshot_out [`N-1:0];
    logic [1:0]     dispatch_num;
    PRF_IDX  [`N-1:0] t_new ;

    // Outputs from RS and D/S Pipeline Register
    D_S_PACKET  d_s_pack [`N:0];
    D_S_PACKET  d_s_pack_reg [`N:0];

    // Outputs from ISSUE stage and ISSUE/EX Pipeline Register
    S_X_PACKET s_x_pack [`N:0];
    S_X_PACKET s_x_pack_reg [`N:0];

    // Outputs from EX-Stage and EX/COM Pipeline Register
    X_C_PACKET x_c_pack [`N-1:0];
    X_C_PACKET x_c_pack_reg [`N-1:0];
    COND_BRANCH_PACKET cond_pack, cond_pack_reg;
    MISPREDICT_PACKET mispredict_pack_out;
    ETB_TAG_PACKET  etb_bus [`N-1:0];

    // Outputs from COM-Stage
    X_C_PACKET [`N-1:0] cdb;

    // Outputs from Retire-Stage
    logic [1:0] freelist_free_num;
    logic       stall_fetch;


    // ROB
    logic [1:0]         rob_space_avail;
    ROB_IDX         rob_index [`N-1:0];
    RETIRE_PACKET   [`N-1:0] rob_commit_pack;

    // Branch Stack
    logic [`MT_SIZE-1:0]    mt_BS_out;
    FLIST_IDX       tail_ptr_out;
    ROB_IDX         rob_index_out;
    logic [1:0]     branch_stack_space_avail;
    ADDR            pc_BS_out;

    // Freelist
    FLIST_IDX   BS_tail [`N-1:0];
    logic [1:0] avail_num;

    // PRF
    logic      [`N-1:0] write_enable;
    PRF_IDX    [`N-1:0] write_index;
    DATA       [`N-1:0] write_data;
    DATA   [`N-1:0] write_data_reg;
    DATA       [`N:0] rs1_value;
    DATA       [`N:0] rs2_value;
    PRF_IDX    [`N:0] read_idx_1;
    PRF_IDX    [`N:0] read_idx_2;

    always_comb begin
        for(int i = 0; i < `N + 1; i++) begin
            read_idx_1[i] = d_s_pack_reg[i].t1;
            read_idx_2[i] = d_s_pack_reg[i].t2;
        end
    end

    // CDB_Arbiter
    typedef enum logic [2:0] {
        MULT_1 = 3'd0,
        MULT_1_ALU_1 = 3'd1,
        ALU_1 = 3'd2,
        ALU_2 = 3'd3,
        NONE  = 3'd4
     } cdb_arbiter_state_t;

    logic   cdb_req_mult, cdb_gnt_mult;
    logic   cdb_req_alu [`N-1:0];
    logic   cdb_gnt_alu [`N-1:0];
    cdb_arbiter_state_t cdb_arbiter_state;
    logic [`N-1:0] alu_ready_reg1;
    logic [`N-1:0] alu_ready_reg2;
    logic mult_ready_reg1;
    logic mult_ready_reg2;
    logic [`N-1:0] alu_ready_reg_in;
    logic mult_ready_reg_in;

    // RS
    logic [1:0] rs_empty_entries_num;



    // Outputs from MEM-Stage to memory
    ADDR        Dmem_addr;
    MEM_BLOCK   Dmem_store_data;
    MEM_COMMAND Dmem_command;
    MEM_SIZE    Dmem_size;

    // Outputs from Retire stage
    RETIRE_PACKET [`N-1:0] commit_pack;

    // Logic for stalling memory stage
    logic       load_stall;
    logic       new_load;
    logic       mem_tag_match;
    logic       rd_mem_q;       // previous load
    MEM_TAG     outstanding_mem_tag;    // tag load is waiting in
    MEM_COMMAND Dmem_command_filtered;  // removes redundant loads

    //////////////////////////////////////////////////
    //                                              //
    //                Memory Outputs                //
    //                                              //
    //////////////////////////////////////////////////

    // these signals go to and from the processor and memory
    // we give precedence to the mem stage over instruction fetch
    // note: there will be a 100ns memory latency in the final project

    // always_comb begin
    //     if (Dmem_command != MEM_NONE) begin  // read or write DATA from memory
    //         proc2mem_command = Dmem_command_filtered;
    //         proc2mem_size    = Dmem_size;
    //         proc2mem_addr    = Dmem_addr;
    //     end else begin                      // read an INSTRUCTION from memory
    //         proc2mem_command = Imem_command;
    //         proc2mem_addr    = Imem_addr;
    //         proc2mem_size    = DOUBLE;      // instructions load a full memory line (64 bits)
    //     end
    //     proc2mem_data = Dmem_store_data;
    // end

    assign proc2mem_command = 2'h1;
    assign proc2mem_size    = DOUBLE;

    //////////////////////////////////////////////////
    //                                              //
    //                  Valid Bit                   //
    //                                              //
    //////////////////////////////////////////////////

    // This state controls the stall signal that artificially forces IF
    // to stall until the previous instruction has completed.

    logic if_valid, start_valid_on_reset;


    always_ff @(posedge clock) begin
        // Start valid on reset. Other stages (ID,EX,MEM,WB) start as invalid
        // Using a separate always_ff is necessary since if_valid is combinational
        // Assigning if_valid = reset doesn't work as you'd hope :/
        start_valid_on_reset <= reset;
    end

    // valid bit will cycle through the pipeline and come back from the wb stage
    //make sure it goes low on mispredict
    assign if_valid = ! global_mispredict;


    //for milestone
    assign fetch_accepted = f_pack[0].valid + f_pack[1].valid;
    //////////////////////////////////////////////////
    //                                              //
    //   Step 8: expose branch redirect signals     //
    //                                              //
    //////////////////////////////////////////////////
 
    // mispredict_pack_reg is registered one cycle after the execute stage
    // detects a misprediction.  It carries correct_next_pc.
    assign branch_taken  = mispredict_pack_out.valid ? mispredict_pack_out.take_branch : 0;
    assign branch_target = mispredict_pack_out.valid? mispredict_pack_out.correct_next_pc : 0;
    assign mispredicted  = global_mispredict;

    //////////////////////////////////////////////////
    //                                              //
    //                Fetch-stage                   //
    //                                              //
    //////////////////////////////////////////////////
    // stage_if no longer manages its own PC.
    // We pass tb_PC (from testbench) and tb_imem_data (direct memory line).
    stage_if stage_if_0 (
        .clock          (clock),
        .reset          (reset),
        .if_valid       (if_valid),
        // ---- direct-fetch inputs (replaces Imem_addr / Imem_data round-trip) ----
        .tb_PC          (tb_PC),
        .Imem_data      (tb_imem_data),
        // ---- other control ----
        .mispredict_pack (mispredict_pack_reg),
        .fetch_req      (can_fetch_num),
        .stop_fetch     (stall_fetch),
        // ---- outputs ----
        .if_packet      (f_pack)
        // Imem_addr output removed — testbench owns the PC
    );

    // stage_if stage_if_0 (
    //     //Input
    //     .clock(clock),
    //     .reset(reset),
    //     .if_valid(if_valid),
    //     .Imem_data(mem2proc_data),
    //     .mispredict_pack(mispredict_pack_reg),
    //     .fetch_req(can_fetch_num),
    //     .stop_fetch(stall_fetch),
        
    //     //Output
    //     .if_packet(f_pack),
    //     .Imem_addr(proc2mem_addr)
    // );

    //////////////////////////////////////////////////
    //                                              //
    //      Fetch / Dispatch Pipeline Register      //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            f_pack_reg    <= '{default: '0};
            dispatch_num_reg <= '0;
        end else begin
            f_pack_reg    <= f_pack;
            dispatch_num_reg <= dispatch_num;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //                Fetch buffer                  //
    //                                              //
    //////////////////////////////////////////////////

    fetch_buffer fetch_buffer_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .mispredicted(global_mispredict),
        .dispatch_num_req(dispatch_num_reg),
        .fetch_pack(f_pack_reg),

        // Output
        .can_fetch_num(can_fetch_num),
        .dispatch_pack(f_d_pack)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                Dispatch-Stage                //
    //                                              //
    //////////////////////////////////////////////////

    stage_dispatch stage_dispatch_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .f_d_pack(f_d_pack),
        .rs_empty_entries_num(rs_empty_entries_num),
        .rob_space_avail(rob_space_avail),
        .branch_stack_space_avail(branch_stack_space_avail),
        .t_new(t_new),
        .avail_num(avail_num),
        .cdb(cdb),
        .resolved(global_resolve),
        .resolved_bmask_index(global_resolve_index),
        .mispredicted(global_mispredict),
        .mispredicted_bmask_index(global_mispredict_index),
        .mispredicted_bmask(global_mispredict_bmask),
        .maptable_snapshot_in(mt_BS_out),

        // Output
        .dispatch_valid(dispatch_valid),
        .dispatch_pack(dispatch_out_pack),
        .branch_encountered(branch_encountered),
        .branch_index(branch_index),
        .maptable_snapshot_out(maptable_snapshot_out),
        .pc_snapshot_out(pc_snapshot_out),
        .dispatch_num(dispatch_num)
    );
    

    //////////////////////////////////////////////////
    //                                              //
    //         Dispatch/ISSUE Pipeline Register     //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            d_s_pack_reg    <= '{default: '0};
        end else begin
            d_s_pack_reg    <= d_s_pack;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //               ISSUE-Stage                    //
    //                                              //
    //////////////////////////////////////////////////
    
    stage_issue stage_issue_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .issue_pack(d_s_pack_reg),
        .rs1_value(rs1_value),
        .rs2_value(rs2_value),
        .resolved(global_resolve),
        .resolved_bmask_index(global_resolve_index),
        .mispredicted(global_mispredict),
        .mispredicted_bmask_index(global_mispredict_index),

        // Output
        .next_s_x_pack(s_x_pack)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           ISSUE/EX Pipeline Register         //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            s_x_pack_reg    <= '{default: '0};;
        end else begin
            s_x_pack_reg    <= s_x_pack;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //                  EX-Stage                    //
    //                                              //
    //////////////////////////////////////////////////
    

    stage_execute stage_execute_0 (
        // Input
        .clock (clock),
        .reset (reset),
        .s_x_pack(s_x_pack_reg),
        .mult_ready(mult_ready_reg_in),
        .alu_ready(alu_ready_reg_in),
        
        // Output
        .x_c_pack(x_c_pack),
        .conditional_branch_out(cond_pack),
        .cdb_req_mult(cdb_req_mult),
        .mispredict_signal_out(global_mispredict),
        .mispredict_index_out(global_mispredict_index),
        .mispredict_bmask_out(global_mispredict_bmask),
        .resolve_index_out(global_resolve_index),
        .resolve_signal_out(global_resolve),
        .early_tag_bus(etb_bus),
        .mispredict_pack_out(mispredict_pack_out)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           EX/COM Pipeline Register           //
    //                                              //
    //////////////////////////////////////////////////
    //don't need to flush the reg here
    always_ff @(posedge clock) begin
        if(reset) begin
            x_c_pack_reg    <= '{default: '0};;
            cond_pack_reg   <= '{default: '0};;
            //mispredict_pack_reg <= '{default: '0};;
        end else begin
            x_c_pack_reg    <= x_c_pack;
            cond_pack_reg   <= cond_pack;
            //mispredict_pack_reg <= mispredict_pack_out;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //                 cdb_arbiter                  //
    //                                              //
    //////////////////////////////////////////////////
    
    //we will always grant mult, so cdb_req_mult just means if there's a mult inst in that stage.
    always_comb begin
        cdb_arbiter_state = NONE;  // default
        if(cdb_req_alu[0] && cdb_req_mult) begin
            cdb_arbiter_state = MULT_1_ALU_1;
        end else if(cdb_req_mult && !cdb_req_alu[0]) begin
            cdb_arbiter_state = MULT_1;
        end else if(!cdb_req_mult && cdb_req_alu[0] && !cdb_req_alu[1]) begin
            cdb_arbiter_state = ALU_1;
        end else if(!cdb_req_mult && cdb_req_alu[0] && cdb_req_alu[1])  begin           
            cdb_arbiter_state = ALU_2;
        end

        case (cdb_arbiter_state)
            MULT_1: begin
                cdb_gnt_alu[0] = 0;
                cdb_gnt_alu[1] = 0;
            end
            MULT_1_ALU_1: begin
                cdb_gnt_alu[0] = 1;
                cdb_gnt_alu[1] = 0;
            end
            ALU_1: begin
                cdb_gnt_alu[0] = 1;
                cdb_gnt_alu[1] = 0;
            end
            ALU_2: begin
                cdb_gnt_alu[0] = 1;
                cdb_gnt_alu[1] = 1;
            end
            NONE: begin
                cdb_gnt_alu[0] = 0;
                cdb_gnt_alu[1] = 0;
            end
        endcase
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < `N; i++) begin
                alu_ready_reg1[i] <= 'd0;
                alu_ready_reg2[i] <= 'd0;
            end
            mult_ready_reg1 <= 1'b0;
            mult_ready_reg2 <= 1'b0;
        end else begin
            for (int i = 0; i < `N; i++) begin
                alu_ready_reg1[i] <= cdb_gnt_alu[i];
                alu_ready_reg2[i] <= alu_ready_reg1[i];
            end
            mult_ready_reg1 <= cdb_req_mult; // we always grant mult, so just check if there's a mult request
            mult_ready_reg2 <= mult_ready_reg1;
        end
    end

    assign alu_ready_reg_in = alu_ready_reg2;
    assign mult_ready_reg_in = mult_ready_reg2;  

    //////////////////////////////////////////////////
    //                                              //
    //                 COM-Stage                    //
    //                                              //
    //////////////////////////////////////////////////

    stage_complete stage_complete_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .x_c_packet(x_c_pack_reg),
        .branch_mispredicted(global_mispredict),
        .mispred_mask_idx(global_mispredict_index),

        // Output
        .cdb(cdb),
        .write_en(write_enable),
        .prf_index(write_index),
        .data_for_prf(write_data)
    );

    always_ff @(posedge clock) begin
        if(reset) write_data_reg<='0;
        else write_data_reg<= write_data;
    end
    //////////////////////////////////////////////////
    //                                              //
    //           Retire stage                       //
    //                                              //
    //////////////////////////////////////////////////

    stage_retire stage_retire_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .rob_commit_pack(rob_commit_pack),

        // Output
        .freelist_free_num(freelist_free_num),
        .commit_pack(commit_pack),
        .stall_fetch(stall_fetch)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Physical Register File             //
    //                                              //
    //////////////////////////////////////////////////


    regfile regfile0 (
        // Input
        .clock(clock),
        .reset(reset),
        .read_idx_1(read_idx_1),
        .read_idx_2(read_idx_2),
        .write_idx(write_index),
        .write_en(write_enable),
        .write_data(write_data),
        // Output
        .read_out_1(rs1_value),
        .read_out_2(rs2_value)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Rob                                //
    //                                              //
    //////////////////////////////////////////////////
    

    rob rob_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .dispatch_pack(dispatch_out_pack),
        .mispredicted(global_mispredict),
        .mispredicted_index(rob_index_out), 
        .cdb(cdb),
        .cond_branch_in(cond_pack_reg),

        // Output
        .rob_commit(rob_commit_pack),
        .rob_space_avail(rob_space_avail),
        .rob_index(rob_index)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Freelist                           //
    //                                              //
    //////////////////////////////////////////////////

    freelist freelist_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .retire_num(freelist_free_num),
        .Branch_stack_H(tail_ptr_out),
        .dispatch_valid(dispatch_valid),
        .is_branch(branch_encountered),
        .mispredicted(global_mispredict),
        
        // Output 
        .BS_tail(BS_tail),
        .t(t_new),
        .avail_num(avail_num)
    );   

    //////////////////////////////////////////////////
    //                                              //
    //           Branch Stack                       //
    //                                              //
    //////////////////////////////////////////////////


    branch_stack branch_stack_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .mt_snapshot_in(maptable_snapshot_out),
        .mispredicted(global_mispredict),
        .mispredicted_idx(global_mispredict_index),
        .tail_ptr_in(BS_tail),
        .branch_encountered(branch_encountered),
        .branch_idx(branch_index),
        .pc_snapshot_in(pc_snapshot_out),
        .resolved(global_resolve),
        .resolved_bmask_index(global_resolve_index),
        .rob_index_in(rob_index),

        // Output
        .mt_snapshot_out(mt_BS_out),
        .tail_ptr_out(tail_ptr_out),
        .rob_index_out(rob_index_out),
        .branch_stack_space_avail(branch_stack_space_avail),
        .pc_snapshot_out(pc_BS_out)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Reservation Station                //
    //                                              //
    //////////////////////////////////////////////////

    rs rs_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .mispredicted(global_mispredict),
        .mispredicted_bmask_index(global_mispredict_index),
        .resolved(global_resolve),
        .resolved_bmask_index(global_resolve_index),
        .rob_index(rob_index),
        .dispatch_pack(dispatch_out_pack),
        .cdb(cdb),
        .early_tag_bus(etb_bus),
        .cdb_gnt_alu(cdb_gnt_alu),
        

        // Output
        .cdb_req_alu(cdb_req_alu),
        .issue_pack(d_s_pack),
        .rs_empty_entries_num(rs_empty_entries_num),
        .dbg_issue_count()
    );


    //////////////////////////////////////////////////
    //                                              //
    //               Pipeline Outputs               //
    //                                              //
    //////////////////////////////////////////////////

    // Output the committed instruction to the testbench for counting
    always_comb begin
        committed_insts = commit_pack;
        committed_insts[0].data = write_data_reg[0];
        committed_insts[1].data = write_data_reg[1];
    end


endmodule // pipeline
