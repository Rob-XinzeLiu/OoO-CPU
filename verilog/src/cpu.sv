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

    input MEM_TAG   mem2proc_transaction_tag, // Memory tag for current transaction
    input MEM_BLOCK mem2proc_data,            // Data coming back from memory
    input MEM_TAG   mem2proc_data_tag,        // Tag for which transaction data is for

    output MEM_COMMAND proc2mem_command, // Command sent to memory
    output ADDR        proc2mem_addr,    // Address sent to memory
    output MEM_BLOCK   proc2mem_data,    // Data sent to memory
    output MEM_SIZE    proc2mem_size,    // Data size sent to memory

    // Note: these are assigned at the very bottom of the module
    output COMMIT_PACKET [`N-1:0] committed_insts,

    // Debug outputs: these signals are solely used for debugging in testbenches
    // You should definitely change these for the final project
    output ADDR  if_NPC_dbg,
    output DATA  if_inst_dbg,
    output logic if_valid_dbg,
    output ADDR  if_id_NPC_dbg,
    output DATA  if_id_inst_dbg,
    output logic if_id_valid_dbg,
    output ADDR  id_ex_NPC_dbg,
    output DATA  id_ex_inst_dbg,
    output logic id_ex_valid_dbg,
    output ADDR  ex_mem_NPC_dbg,
    output DATA  ex_mem_inst_dbg,
    output logic ex_mem_valid_dbg,
    output ADDR  mem_wb_NPC_dbg,
    output DATA  mem_wb_inst_dbg,
    output logic mem_wb_valid_dbg
);

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

    // Outputs from Fetch buffer
    F_D_PACKET  f_d_pack[`N-1:0];

    // Outputs from Dispatch stage
    D_S_PACKET  dispatch_out_pack [`N-1:0];

    // Outputs from RS and D/S Pipeline Register
    D_S_PACKET  d_s_pack [`N-1:0];
    D_S_PACKET  d_s_pack_reg [`N-1:0];

    // Outputs from ISSUE stage and ISSUE/EX Pipeline Register
    S_X_PACKET s_x_pack [`N-1:0];
    S_X_PACKET s_x_pack_reg [`N-1:0];

    // Outputs from EX-Stage and EX/COM Pipeline Register
    X_C_PACKET x_c_pack [`N-1:0];
    X_C_PACKET x_c_pack_reg [`N-1:0];
    COND_BRANCH_PACKET cond_pack, cond_pack_reg;
    ETB_TAG_PACKET  etb_bus [`N-1:0];

    // Outputs from COM-Stage
    X_C_PACKET cdb [`N-1:0];



    // Outputs from MEM-Stage to memory
    ADDR        Dmem_addr;
    MEM_BLOCK   Dmem_store_data;
    MEM_COMMAND Dmem_command;
    MEM_SIZE    Dmem_size;

    // Outputs from WB-Stage (These loop back to the register file in ID)
    COMMIT_PACKET wb_packet;

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

    always_comb begin
        if (Dmem_command != MEM_NONE) begin  // read or write DATA from memory
            proc2mem_command = Dmem_command_filtered;
            proc2mem_size    = Dmem_size;
            proc2mem_addr    = Dmem_addr;
        end else begin                      // read an INSTRUCTION from memory
            proc2mem_command = Imem_command;
            proc2mem_addr    = Imem_addr;
            proc2mem_size    = DOUBLE;      // instructions load a full memory line (64 bits)
        end
        proc2mem_data = Dmem_store_data;
    end

    //////////////////////////////////////////////////
    //                                              //
    //                  Valid Bit                   //
    //                                              //
    //////////////////////////////////////////////////

    // This state controls the stall signal that artificially forces IF
    // to stall until the previous instruction has completed.

    logic if_valid, start_valid_on_reset, wb_valid;


    always_ff @(posedge clock) begin
        // Start valid on reset. Other stages (ID,EX,MEM,WB) start as invalid
        // Using a separate always_ff is necessary since if_valid is combinational
        // Assigning if_valid = reset doesn't work as you'd hope :/
        start_valid_on_reset <= reset;
    end

    // valid bit will cycle through the pipeline and come back from the wb stage
    assign if_valid = start_valid_on_reset || wb_valid;

    //////////////////////////////////////////////////
    //                                              //
    //                Fetch-stage                   //
    //                                              //
    //////////////////////////////////////////////////

    stage_if stage_if_0 (
        .clock(clock),



    );

    //////////////////////////////////////////////////
    //                                              //
    //      Fetch / Dispatch Pipeline Register      //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            f_pack_reg    <= '0;
        end else begin
            f_pack_reg    <= f_pack;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //                Fetch buffer                  //
    //                                              //
    //////////////////////////////////////////////////
    logic [1:0] can_fetch_num;

    fetch_buffer fetch_buffer_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .mispredicted(global_mispredict),
        .dispatch_num_req(dispatch_num),
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
    logic [`N-1:0]  dispatch_valid;
    logic           branch_encountered;
    B_MASK          branch_index;
    logic [`MT_SIZE-1:0] maptable_snapshot_out;
    ADDR            pc_snapshot_out;
    logic [1:0]     dispatch_num;

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
        .maptable_snapshot_in(mt_BS_out)

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
            d_s_pack_reg    <= '0;
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
            s_x_pack_reg    <= '0;
        end else begin
            s_x_pack_reg    <= s_x_pack;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //                  EX-Stage                    //
    //                                              //
    //////////////////////////////////////////////////
    
    logic   global_mispredict;
    logic   global_resolve;
    B_MASK  global_mispredict_index;
    B_MASK  global_resolve_index;
    B_MASK  global_mispredict_bmask;

    stage_execute stage_execute_0 (
        // Input
        .clock (clock),
        .reset (reset),
        .s_x_pack(s_x_pack_reg),
        .mult_ready(mult_ready_reg),
        .alu_ready(alu_ready_reg),
        
        // Output
        .x_c_pack(x_c_pack),
        .conditional_branch_out(cond_pack),
        .cdb_req_mult(cdb_req_mult),
        .mispredict_signal_out(global_mispredict),
        .mispredict_index_out(global_mispredict_index),
        .mispredict_bmask_out(global_mispredict_bmask),
        .resolve_index_out(global_resolve_index),
        .resolve_signal_out(global_resolve),
        .early_tag_bus(etb_bus)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           EX/COM Pipeline Register           //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            x_c_pack_reg    <= '0;
            cond_pack_reg   <= '0;
        end else begin
            x_c_pack_reg    <= x_c_pack;
            cond_pack_reg   <= cond_pack;
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //                 cdb_arbiter                  //
    //                                              //
    //////////////////////////////////////////////////
    typedef enum logic [2:0] {
        1_MULT,
        1_MULT_1_ALU,
        1_ALU,
        2_ALU,
        NONE,
    } cdb_arbiter_state_t;

    logic   cdb_req_mult, cdb_gnt_mult;
    logic   cdb_req_alu [`N-1:0];
    logic   cdb_gnt_alu [`N-1:0];
    cdb_arbiter_state_t cdb_arbiter_state;
    //we will always grant mult, so cdb_req_mult just means if there's a mult inst in that stage.
    always_comb begin
        cdb_arbiter_state = NONE;  // default
        if(cdb_req_alu[0] && cdb_req_mult) begin
            cdb_arbiter_state = 1_MULT_1_ALU;
        end else if(cdb_req_mult && !cdb_req_alu[0]) begin
            cdb_arbiter_state = 1_MULT;
        end else if(!cdb_req_mult && cdb_req_alu[0] && !cdb_req_alu[1]) begin
            cdb_arbiter_state = 1_ALU;
        end else if(!cdb_req_mult && cdb_req_alu[0] && cdb_req_alu[1])  begin           
            cdb_arbiter_state = 2_ALU;
        end

        case (cdb_arbiter_state)
            1_MULT: begin
                cdb_grant_alu[0] = 0;
                cdb_grant_alu[1] = 0;
            end
            1_MULT_1_ALU: begin
                cdb_grant_alu[0] = 1;
                cdb_grant_alu[1] = 0;
            end
            1_ALU: begin
                cdb_grant_alu[0] = 1;
                cdb_grant_alu[1] = 0;
            end
            2_ALU: begin
                cdb_grant_alu[0] = 1;
                cdb_grant_alu[1] = 1;
            end
            NONE: begin
                cdb_grant_alu[0] = 0;
                cdb_grant_alu[1] = 0;
            end
        endcase
    end

    logic alu_ready_reg [`N-1:0];
    logic mult_ready_reg ;
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < `N; i++) begin
                alu_ready_reg[i] <= 1'b0;
            end
            mult_ready_reg <= 1'b0;
        end else begin
            for (int i = 0; i < `N; i++) begin
                alu_ready_reg[i] <= cdb_grant_alu[i];
            end
            mult_ready_reg <= cdb_req_mult; // we always grant mult, so just check if there's a mult request
        end
    end

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




    //////////////////////////////////////////////////
    //                                              //
    //           Physical Register File             //
    //                                              //
    //////////////////////////////////////////////////
    logic      [`N-1:0] write_enable;
    PRF_IDX    [`N-1:0] write_index;
    DATA       [`N-1:0] write_data;
    DATA       rs1_value, rs2_value;
    PRF_IDX    [`N-1:0] read_idx_1;
    PRF_IDX    [`N-1:0] read_idx_2;

    always_comb begin
        for(int i = 0; i < `N; i++) begin
            read_idx_1 = d_s_pack_reg[i].t1;
            read_idx_2 = d_s_pack_reg[i].t2;
        end
    end


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
    logic           retire_valid;
    logic   [1:0]   retire_num;
    ROB_CNT         rob_space_avail;
    ROB_IDX         rob_index [`N-1:0];

    rob rob_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .dispatch_pack(),
        .mispredicted(global_mispredict),
        .mispredicted_index(rob_index_out), 
        .cdb(cdb),
        .cond_branch_in(cond_pack_reg),

        // Output
        .retire_valid(retire_valid),
        .retire_num(retire_num),
        .rob_space_avail(rob_space_avail),
        .rob_index(rob_index)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Freelist                           //
    //                                              //
    //////////////////////////////////////////////////
    FLIST_CNT   BS_head [`N-1:0];
    PRF_IDX     t_new   [`N-1:0];
    FLIST_CNT   avail_num;

    freelist freelist_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .retire_num(retire_num),
        .retire_valid(retire_valid),
        .Branch_stack_H(Branch_stack_H),
        .dispatch_valid(dispatch_valid),
        .is_branch(branch_encountered),
        .mispredicted(global_mispredict),
        
        // Output 
        .BS_head(BS_head),
        .t(t_new),
        .avail_num(avail_num)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Branch Stack                       //
    //                                              //
    //////////////////////////////////////////////////
    FLIST_SZ    Branch_stack_H;
    logic [`MT_SIZE-1:0]    mt_BS_out;
    logic [`FLIST_SIZE-1:0] tail_ptr_out;
    ROB_IDX         rob_index_out;
    BSTACK_CNT      branch_stack_space_avail;
    ADDR            pc_BS_out;


    branch_stack branch_stack_0 (
        // Input
        .clock(clock),
        .reset(reset),
        .mt_snapshot_in(maptable_snapshot_out),
        .mispredicted(global_mispredict),
        .mispredicted_idx(global_mispredict_index),
        .tail_ptr_in(BS_head),
        .branch_encountered(),
        .branch_idx(branch_index),
        .pc_snapshop_in(pc_snapshot_out),
        .resolved(global_resolve),
        .resolved_bmask_index(global_resolve_index),
        .rob_index_in(rob_index),

        // Output
        .mt_snapshot_out(mt_BS_out),
        .tail_ptr_out(tail_ptr_out),
        .rob_index_out(rob_idx_out),
        .branch_stack_space_avail(branch_stack_space_avail),
        .pc_snapshot_out(pc_BS_out)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Reservation Station                //
    //                                              //
    //////////////////////////////////////////////////
    RS_CNT rs_empty_entries_num;

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
    assign committed_insts[0] = wb_packet;

endmodule // pipeline
