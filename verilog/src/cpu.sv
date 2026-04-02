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

    input MEM_TAG       mem2proc_transaction_tag, // Memory tag for current transaction
    input MEM_BLOCK     mem2proc_data,            // Data coming back from memory
    input MEM_TAG       mem2proc_data_tag,        // Tag for which transaction data is for

    output MEM_COMMAND proc2mem_command, // Command sent to memory
    output ADDR        proc2mem_addr,    // Address sent to memory
    output MEM_BLOCK   proc2mem_data,    // Data sent to memory
    output MEM_SIZE    proc2mem_size,    // Data size sent to memory

    // // Note: these are assigned at the very bottom of the module
    output RETIRE_PACKET [`N-1:0] committed_insts

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


    // From IF stage to memory
    MEM_COMMAND Imem_command; // Command sent to memory

    // Outputs from IF-Stage and IF/ID Pipeline Register
    F_D_PACKET  f_pack [`N-1:0];
    logic [1:0] dispatch_num_reg ;
    ADDR        proc2icache_addr;

 
    // Outputs from Fetch buffer
    F_D_PACKET  f_d_pack[`N-1:0];
    logic [1:0] can_fetch_num;
    logic [1:0] can_fetch_num_reg;

    // Outputs from Dispatch stage
    D_S_PACKET  dispatch_out_pack [`N-1:0];
    logic           dispatch_valid [`N-1:0];
    logic           branch_encountered [`N-1:0];
    B_MASK          branch_index [`N-1:0];
    INST        [`N-1:0] inst;
    logic       [`N-1:0] is_load;
    logic       [`N-1:0] is_store;
    logic       [`N-1:0] is_branch;
    PRF_IDX     [`N-1:0] dest_tag;

    logic [`N-1:0][`MT_SIZE-1:0] maptable_snapshot_out ;
    ADDR            pc_snapshot_out [`N-1:0];
    logic [1:0]     dispatch_num;
    PRF_IDX  [`N-1:0] t_new ;

    // Outputs from RS and D/S Pipeline Register
    D_S_PACKET  d_s_pack [5:0];

    // Outputs from ISSUE stage and ISSUE/EX Pipeline Register
    S_X_PACKET s_x_pack [5:0];
    S_X_PACKET s_x_pack_reg [5:0];

    // Outputs from EX-Stage and EX/COM Pipeline Register
    X_C_PACKET x_c_pack [`N-1:0];
    X_C_PACKET x_c_pack_reg [`N-1:0];
    COND_BRANCH_PACKET cond_pack, cond_pack_reg;
    SQ_PACKET          store_pack, store_pack_reg;
    LQ_PACKET          load_execute_pack;
    MISPREDICT_PACKET mispredict_pack_out;
    ETB_TAG_PACKET  etb_bus [`N-1:0];

    // Outputs from COM-Stage
    X_C_PACKET [`N-1:0] cdb;

    // Outputs from Retire-Stage
    FL_RETIRE_PACKET [`N-1:0] freelist_pack;
    logic       stall_fetch;
    RETIRE_PACKET [`N-1:0] commit_pack;
    SQ_PACKET       store_retire_pack [`N-1:0];


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
    LQ_IDX          BS_lq_tail_out;
    SQ_IDX          BS_sq_tail_out;

    // Freelist
    FLIST_IDX   BS_tail [`N-1:0];
    logic [1:0] avail_num;

    // From icache
    MEM_BLOCK   Icache_data_out;
    logic       Icache_valid_out;
    MEM_COMMAND Imem_command;
    ADDR        Imem_addr;

    // From Predictor
    logic       taken;
    ADDR        PC_taken_addr;
    logic       btb_slot;

    // PRF
    logic      [`N-1:0] write_enable;
    PRF_IDX    [`N-1:0] write_index;
    DATA       [`N-1:0] write_data;
    DATA       [5:0]    rs1_value;
    DATA       [5:0]    rs2_value;
    PRF_IDX    [5:0]    read_idx_1;
    PRF_IDX    [5:0]    read_idx_2;

    always_comb begin
        for(int i = 0; i < 6; i++) begin
            read_idx_1[i] = d_s_pack[i].t1;
            read_idx_2[i] = d_s_pack[i].t2;
        end
    end

    //load queue
    LQ_IDX                lq_index               [`N-1:0];
    LQ_IDX                BS_lq_tail             [`N-1:0];
    logic [1:0]           lq_space_available             ;
    LQ_PACKET             load_packet                    ;
    LQ_PACKET             lq_out                         ;

    //dcache

    dcache_data_t         cache_resp_data; 
    miss_request_t        miss_request;
    MEM_COMMAND           vc2mem_command;
    ADDR                  vc2mem_addr;
    MEM_BLOCK             vc2mem_data;
    MEM_SIZE              vc2mem_size;
    logic                 dcache_can_accept_store;
    logic                 dcache_can_accept_load;

    //mshr

    MEM_COMMAND           mshr2mem_command;
    ADDR                  mshr2mem_addr;
    MEM_SIZE              mshr2mem_size;
    MEM_BLOCK             mshr2mem_data;
    completed_mshr_t      com_miss_req;
    logic                 miss_queue_full;
    logic                 miss_returned;

    //store queue
    SQ_PACKET            sq_out                          ;
    SQ_IDX               BS_sq_tail              [`N-1:0];
    logic [1:0]          sq_space_available              ;
    logic [`SQ_SZ-1:0]   sq_addr_ready_mask              ;
    SQ_IDX               sq_index                [`N-1:0];
    ADDR                 sq_addr_out         [`SQ_SZ-1:0];
    logic                sq_addr_ready_out   [`SQ_SZ-1:0];
    DATA                 sq_data_out         [`SQ_SZ-1:0];
    logic                sq_data_ready_out   [`SQ_SZ-1:0];
    logic [2:0]          sq_funct3_out       [`SQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   sq_valid_out                    ;
    logic [`SQ_SZ-1:0]   sq_valid_out_mask       [`N-1:0];
    SQ_IDX               sq_tail_out             [`N-1:0];

    // CDB_Arbiter
    typedef enum logic [3:0] {
        MULT_1,
        LOAD_1,
        MULT_1_LOAD_1,
        MULT_1_ALU_1,
        LOAD_1_ALU_1,
        ALU_1 ,
        ALU_2 ,
        NONE  
     } cdb_arbiter_state_t;

    logic   cdb_req_mult;
    logic   cdb_req_load;
    logic   cdb_req_alu [`N-1:0];
    logic   cdb_gnt_alu [`N-1:0];
    cdb_arbiter_state_t cdb_arbiter_state;

    // RS
    logic [1:0] rs_empty_entries_num;



    // Outputs from MEM-Stage to memory

    //////////////////////////////////////////////////
    //                                              //
    //                Memory Outputs                //
    //                                              //
    //////////////////////////////////////////////////
    logic icache_gnt, mshr_gnt, dcache_store_gnt;
    logic unanswered_miss, mshr_wait_for_trans, vc_requesting;

    always_comb begin
        icache_gnt = 1'b0;
        mshr_gnt   = 1'b0;
        dcache_store_gnt = 1'b0;
        proc2mem_command = MEM_NONE;


        if(mshr2mem_command == MEM_LOAD && (!unanswered_miss && !vc_requesting)) begin
            mshr_gnt = 1'b1;
            proc2mem_command = mshr2mem_command;
            proc2mem_size    = mshr2mem_size;
            proc2mem_addr    = mshr2mem_addr;
            proc2mem_data    = '0;
        end
        else if(vc2mem_command == MEM_STORE && (!unanswered_miss && !mshr_wait_for_trans))begin 
            dcache_store_gnt = 1'b1;
            proc2mem_command = vc2mem_command;
            proc2mem_size    = vc2mem_size;
            proc2mem_addr    = vc2mem_addr;
            proc2mem_data    = vc2mem_data;
        end else begin
            icache_gnt       = (Imem_command != MEM_NONE);
            proc2mem_command = Imem_command;
            proc2mem_size    = DOUBLE;
            proc2mem_addr    = Imem_addr;
            proc2mem_data    = '0;
        end
    end

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
    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            can_fetch_num_reg <= 2;
        end else begin
            can_fetch_num_reg <= can_fetch_num;
        end
    end

    // stage_if no longer manages its own PC.
    // We pass tb_PC (from testbench) and tb_imem_data (direct memory line).
    stage_if stage_fetch_0 (
        .clock(clock),
        .reset(reset),

        .if_valid(if_valid),
        .stop_fetch(stall_fetch),
        .mispredict_pack(mispredict_pack_out),
        .fetch_req(can_fetch_num_reg),
        // icache
        .icache_data(Icache_data_out),
        .icache_valid(Icache_valid_out),
        // Predictor
        .taken(taken),
        .predicted_addr(PC_taken_addr),
        .btb_slot(btb_slot),
        // Output
        .if_packet(f_pack),
        .proc2icache_addr(proc2icache_addr)
    );

    //////////////////////////////////////////////////
    //                                              //
    //      Fetch / Dispatch Pipeline Register      //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset || global_mispredict) begin
            dispatch_num_reg <= '0;
        end else begin
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
        .fetch_pack(f_pack),

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
        .lq_index_in(lq_index),
        .sq_index_in(sq_index),
        .lq_space_available(lq_space_available),
        .sq_space_available(sq_space_available),
        .sq_valid_mask(sq_valid_out_mask),


        // Output
        .dispatch_valid(dispatch_valid),
        .dispatch_pack(dispatch_out_pack),
        .branch_encountered(branch_encountered),
        .branch_index(branch_index),
        .inst_out(inst),
        .is_load_out(is_load),
        .is_store_out(is_store),
        .is_branch_out(is_branch),
        .dest_tag_out(dest_tag),
        .maptable_snapshot_out(maptable_snapshot_out),
        .pc_snapshot_out(pc_snapshot_out),
        .dispatch_num(dispatch_num)
    );
    

    // //////////////////////////////////////////////////
    // //                                              //
    // //         Dispatch/ISSUE Pipeline Register     //
    // //                                              //
    // //////////////////////////////////////////////////

    // always_ff @(posedge clock) begin
    //     if(reset) begin
    //         d_s_pack_reg <= '{default: '0};
    //     end else begin
    //         for(int i = 0; i < `N+1; i++) begin
    //             if(global_mispredict && 
    //             (d_s_pack[i].bmask & global_mispredict_index)) begin
    //                 d_s_pack_reg[i] <= '{default: '0};
    //             end else begin
    //                 d_s_pack_reg[i] <= d_s_pack[i];
    //             end
    //         end
    //     end
    // end

    //////////////////////////////////////////////////
    //                                              //
    //               ISSUE-Stage                    //
    //                                              //
    //////////////////////////////////////////////////
    
    stage_issue stage_issue_0 (
        // Input
        .issue_pack(d_s_pack),
        .rs1_value(rs1_value),
        .rs2_value(rs2_value),
        .resolved(global_resolve),
        .resolved_bmask_index(global_resolve_index),

        // Output
        .next_s_x_pack(s_x_pack)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           ISSUE/EX Pipeline Register         //
    //                                              //
    //////////////////////////////////////////////////

    always_ff @(posedge clock) begin
        if(reset) begin
            s_x_pack_reg <= '{default: '0};
        end else begin
            for(int i = 0; i < 'd6; i++) begin
                if(global_mispredict && 
                (s_x_pack[i].bmask & global_mispredict_index)) begin
                    s_x_pack_reg[i] <= '{default: '0};
                end else begin
                    s_x_pack_reg[i] <= s_x_pack[i];
                end
            end
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
        .lq_in(lq_out),
        .cdb(cdb),
        
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
        .mispredict_pack_out(mispredict_pack_out),
        .lq_execute_pack(load_execute_pack),
        .sq_execute_pack(store_pack)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           EX/COM Pipeline Register           //
    //                                              //
    //////////////////////////////////////////////////
    //don't need to flush the reg here
    always_ff @(posedge clock) begin
        if(reset) begin
            x_c_pack_reg    <= '{default: '0};
            cond_pack_reg   <= '{default: '0};
            store_pack_reg   <= '{default: '0};

        end else begin
            x_c_pack_reg    <= x_c_pack;
            cond_pack_reg   <= cond_pack;
            store_pack_reg   <= store_pack;
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
        if(cdb_req_load && cdb_req_mult) begin
            cdb_arbiter_state = MULT_1_LOAD_1;
        end else if(cdb_req_mult && !cdb_req_load && cdb_req_alu[0]) begin
            cdb_arbiter_state = MULT_1_ALU_1;
        end else if(cdb_req_mult && !cdb_req_load && !cdb_req_alu[0] && !cdb_req_alu[1]) begin
            cdb_arbiter_state = MULT_1;
        end else if(!cdb_req_mult && cdb_req_load && cdb_req_alu[0])  begin           
            cdb_arbiter_state = LOAD_1_ALU_1;
        end else if (!cdb_req_mult && cdb_req_load && !cdb_req_alu[0]) begin
            cdb_arbiter_state = LOAD_1;
        end else if (!cdb_req_mult && !cdb_req_load && cdb_req_alu[0] && cdb_req_alu[1])begin
            cdb_arbiter_state = ALU_2;
        end else if (!cdb_req_mult && !cdb_req_load && cdb_req_alu[0] && !cdb_req_alu[1]) begin
            cdb_arbiter_state = ALU_1;
        end else begin
            cdb_arbiter_state = NONE;
        end

        case (cdb_arbiter_state)
            MULT_1_LOAD_1: begin
                cdb_gnt_alu[0] = 0;
                cdb_gnt_alu[1] = 0;
            end
            MULT_1_ALU_1: begin
                cdb_gnt_alu[0] = 1;
                cdb_gnt_alu[1] = 0;
            end
            ALU_1, LOAD_1_ALU_1: begin
                cdb_gnt_alu[0] = 1;
                cdb_gnt_alu[1] = 0;
            end      
            LOAD_1, MULT_1: begin
                cdb_gnt_alu[0] = 0;
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

    //////////////////////////////////////////////////
    //                                              //
    //                 COM-Stage                    //
    //                                              //
    //////////////////////////////////////////////////

    stage_complete stage_complete_0 (
        // Input
        .x_c_packet(x_c_pack_reg),

        // Output
        .cdb(cdb),
        .write_en(write_enable),
        .prf_index(write_index),
        .data_for_prf(write_data)
    );


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
        .freelist_pack(freelist_pack),
        .store_retire_pack(store_retire_pack),
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
        .sq_in(store_pack_reg),

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
        .freelist_pack(freelist_pack),
        .Branch_stack_T(tail_ptr_out),
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
    //           Icache                             //
    //                                              //
    //////////////////////////////////////////////////
    icache icache_0 (
        .clock(clock),
        .reset(reset),
        // Input
        .grant(icache_gnt),
        .Imem2proc_transaction_tag(mem2proc_transaction_tag),
        .Imem2proc_data(mem2proc_data),
        .Imem2proc_data_tag(mem2proc_data_tag),
        .proc2Icache_addr(proc2icache_addr),

        // Output
        .proc2Imem_command(Imem_command),
        .proc2Imem_addr(Imem_addr),
        .Icache_data_out(Icache_data_out),
        .Icache_valid_out(Icache_valid_out),
        .unanswered_miss(unanswered_miss)
    );

     //////////////////////////////////////////////////
    //                                              //
    //           Branch Predictor                   //
    //                                              //
    //////////////////////////////////////////////////

    branch_predicotr predictor_0 (
        .clock(clock),
        .reset(reset),
        // Input
        .proc2icache_addr(proc2icache_addr),
        .conditional_branch_out(cond_pack_reg),
        .mispredict_pack(mispredict_pack_out),
        // Output
        .taken(taken),
        .PC_taken_addr(PC_taken_addr),
        .btb_slot(btb_slot)
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
        .lq_tail_in(BS_lq_tail),
        .sq_tail_in(BS_sq_tail),

        // Output
        .mt_snapshot_out(mt_BS_out),
        .tail_ptr_out(tail_ptr_out),
        .rob_index_out(rob_index_out),
        .branch_stack_space_avail(branch_stack_space_avail),
        .pc_snapshot_out(pc_BS_out),
        .lq_tail_out(BS_lq_tail_out),
        .sq_tail_out(BS_sq_tail_out)
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
        .sq_valid_in(sq_valid_out),
        .sq_addr_ready_mask(sq_addr_ready_mask),
        

        // Output
        .cdb_req_alu(cdb_req_alu),
        .issue_pack(d_s_pack),
        .rs_empty_entries_num(rs_empty_entries_num)
    );

    //////////////////////////////////////////////////
    //                                              //
    //               load      queue                //
    //                                              //
    //////////////////////////////////////////////////
    load_queue lq_0 (
        //input
        .clock(clock),
        .reset(reset),
        .inst_in(inst),
        .is_load(is_load),
        .is_branch(is_branch),
        .dest_tag_in(dest_tag),
        .rob_index(rob_index),
        .mispredicted(global_mispredict),
        .BS_lq_tail_in(BS_lq_tail_out),
        .sq_addr_in(sq_addr_out),
        .sq_addr_ready_in(sq_addr_ready_out),
        .sq_data_in(sq_data_out),
        .sq_data_ready_in(sq_data_ready_out),
        .sq_valid_in(sq_valid_out),
        .sq_valid_in_mask(sq_valid_out_mask),
        .sq_tail_in(sq_tail_out),
        .sq_funct3_in(sq_funct3_out),
        .load_execute_pack(load_execute_pack),
        .dcache_can_accept_load(dcache_can_accept_load),
        .dcache_load_packet(cache_resp_data),

        //output
        .lq_index(lq_index),
        .BS_lq_tail_out(BS_lq_tail),
        .lq_space_available(lq_space_available),
        .load_packet(load_packet),
        .cdb_req_load(cdb_req_load),
        .lq_out(lq_out)
    );

    //////////////////////////////////////////////////
    //                                              //
    //              Dcache                          //
    //                                              //
    //////////////////////////////////////////////////

    Dcache dcache (
        .clock(clock),
        .reset(reset),
        .load_req_pack(load_packet),
        .store_req_pack(sq_out),
        .com_miss_req(com_miss_req),
        .miss_returned(miss_returned),//missing
        .miss_queue_full(miss_queue_full),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .cache_resp_data(cache_resp_data),
        .miss_request(miss_request),
        .vc2mem_command(vc2mem_command),
        .vc2mem_addr(vc2mem_addr),
        .vc2mem_data(vc2mem_data),
        .vc2mem_size(vc2mem_size),
        .dcache_can_accept_store(dcache_can_accept_store),
        .dcache_can_accept_load(dcache_can_accept_load),
        .vc_requesting(vc_requesting)
    );

    mshr mshr (
        .clock(clock),
        .reset(reset),
        .dcache_miss_req(miss_request),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .mem2proc_data_tag(mem2proc_data_tag),
        .mem2proc_data(mem2proc_data),
        .mshr2mem_command(mshr2mem_command),
        .mshr2mem_addr(mshr2mem_addr),
        .mshr2mem_size(mshr2mem_size),
        .mshr2mem_data(mshr2mem_data),
        .com_miss_req(com_miss_req),
        .miss_queue_full(miss_queue_full),
        .miss_returned(miss_returned),
        .mshr_wait_for_trans(mshr_wait_for_trans)
    );


    //////////////////////////////////////////////////
    //                                              //
    //              store      queue                //
    //                                              //
    //////////////////////////////////////////////////
    store_queue sq_0 (
        //input
        .clock(clock),
        .reset(reset),
        .inst_in(inst),
        .is_load(is_load),
        .is_store(is_store),
        .is_branch(is_branch),
        .rob_index(rob_index),
        .store_execute_pack(store_pack),
        .store_retire_pack(store_retire_pack),
        .mispredicted(global_mispredict),
        .BS_sq_tail_in(BS_sq_tail_out),
        .dcache_can_accept(dcache_can_accept_store),

        //output
        .sq_out(sq_out),
        .BS_sq_tail_out(BS_sq_tail),
        .sq_space_available(sq_space_available),
        .sq_addr_ready_mask(sq_addr_ready_mask),
        .sq_index(sq_index),
        .sq_addr_out(sq_addr_out),
        .sq_addr_ready_out(sq_addr_ready_out),
        .sq_data_out(sq_data_out),
        .sq_data_ready_out(sq_data_ready_out),
        .sq_funct3_out(sq_funct3_out),
        .sq_valid_out(sq_valid_out),
        .sq_valid_out_mask(sq_valid_out_mask),
        .sq_tail_out(sq_tail_out)
    );





    //////////////////////////////////////////////////
    //                                              //
    //               Pipeline Outputs               //
    //                                              //
    //////////////////////////////////////////////////

    // Output the committed instruction to the testbench for counting

    assign committed_insts = commit_pack;



endmodule // pipeline
