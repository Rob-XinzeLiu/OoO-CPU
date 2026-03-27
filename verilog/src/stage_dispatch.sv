`include "sys_defs.svh"
module stage_dispatch (
    input logic                             clock                               , 
    input logic                             reset                               , 
    input F_D_PACKET                        f_d_pack                    [`N-1:0], // from fetch buffer
    input logic [1:0]                       rs_empty_entries_num                , // from RS
    input logic [1:0]                       rob_space_avail                     , // from ROB
    input logic [1:0]                       branch_stack_space_avail            , //from branch stack
    //from freelist
    input PRF_IDX           [`N-1:0]        t_new                               , // from freelist
    input logic [1:0]                       avail_num                           , // from freelist   
    output logic                            dispatch_valid              [`N-1:0], // to freelist
                       
    input X_C_PACKET                        [`N-1:0]  cdb                       , // updating map table ready bit
    
    //For branch resolve
    input logic                             resolved                            ,
    input B_MASK                            resolved_bmask_index                ,
    //For branch mispredict
    input logic                             mispredicted                        ,
    input B_MASK                            mispredicted_bmask_index            , 
    input B_MASK                            mispredicted_bmask                  ,

    output D_S_PACKET                       dispatch_pack               [`N-1:0],
    output logic                            branch_encountered          [`N-1:0],
    output B_MASK                           branch_index                [`N-1:0], 
    //for lsq
    input  LQ_IDX                           lq_index_in                 [`N-1:0],
    input  SQ_IDX                           sq_index_in                 [`N-1:0],
    input  logic [1:0]                      lq_space_available                  ,
    input  logic [1:0]                      sq_space_available                  ,
    input  logic [`SQ_SZ-1:0]               sq_valid_mask               [`N-1:0],
    output INST     [`N-1:0]                inst_out                            ,
    output logic    [`N-1:0]                is_load_out                         ,
    output logic    [`N-1:0]                is_store_out                        ,
    output logic    [`N-1:0]                is_branch_out                       ,
    output PRF_IDX  [`N-1:0]                dest_tag_out                        ,
    // maptable snapshot
    input  logic [`MT_SIZE-1:0]             maptable_snapshot_in                ,                         
    output logic  [`N-1:0][`MT_SIZE-1:0]    maptable_snapshot_out               ,

    output ADDR                             pc_snapshot_out             [`N-1:0],
   
    output logic [1:0]                      dispatch_num             
);

    function automatic logic [1:0] min2(
        input logic [1:0]   a,
        input logic [1:0]   b
    );
        return (a < b) ? a : b;
    endfunction

    typedef struct packed {
        ALU_OPA_SELECT opa_select;
        ALU_OPB_SELECT opb_select;
        logic          has_dest; // if there is a destination register
        ALU_FUNC       alu_func;
        logic          mult, rd_mem, wr_mem, cond_branch, uncond_branch;
        logic          csr_op; // used for CSR operations, we only use this as a cheap way to get the return code out
        logic          halt;   // non-zero on a halt
        logic          illegal;
    } DECODE_PACKET;

    DECODE_PACKET   [`N-1:0]    decode_pack;

    REG_IDX [`N-1:0] r1;
    REG_IDX [`N-1:0] r2;
    REG_IDX [`N-1:0] rd;
    ALU_OPA_SELECT [`N-1:0] opa_select;
    ALU_OPB_SELECT [`N-1:0] opb_select; 
    logic [`N-1:0] has_dest, is_branch, halt, cond_branch, is_load, is_store;

    PRF_IDX         [`N-1:0]    t1, t2, told;
    logic           [`N-1:0]    t1_ready, t2_ready;
    logic           [`N-1:0] [`MT_SIZE-1:0]  snapshot_out;
    BMASK_CNT      branch_count, next_branch_count;
    logic [1:0]      branch_avail_slot;
    logic [1:0]      small1, small2, small3, small4, small5;
    
    // Bmask
    B_MASK  bmask, next_bmask, bmask_idx_0, bmask_idx_1;
   
    //for lsq
    assign is_branch_out = is_branch;
    assign is_load_out = is_load;
    assign is_store_out = is_store;
    assign dest_tag_out = t_new;
    always_comb begin
        for(int i = 0; i < `N; i++) begin
            if(f_d_pack[i].valid) begin
                inst_out[i] =  f_d_pack[i].inst;
            end
        end
    end


    for (genvar i=0; i<`N; i++) begin : decoders
        decoder decoderN (
            .inst               (f_d_pack[i].inst),
            .valid              (f_d_pack[i].valid),
            .opa_select         (decode_pack[i].opa_select),
            .opb_select         (decode_pack[i].opb_select),
            .has_dest           (decode_pack[i].has_dest),
            .alu_func           (decode_pack[i].alu_func),
            .mult               (decode_pack[i].mult),
            .rd_mem             (decode_pack[i].rd_mem),
            .wr_mem             (decode_pack[i].wr_mem),
            .cond_branch        (decode_pack[i].cond_branch),
            .uncond_branch      (decode_pack[i].uncond_branch),
            .csr_op             (decode_pack[i].csr_op),
            .halt               (decode_pack[i].halt),
            .illegal            (decode_pack[i].illegal)
        );
    end


    typedef enum logic [2:0] {
        ONE_NON_BRANCH = 3'd0,
        ONE_BRANCH = 3'd1,
        TWO_BRANCH = 3'd2,
        TWO_NON_BRANCH = 3'd3,
        NON_BRANCH_AFTER_BRANCH = 3'd4,
        BRANCH_AFTER_NON_BRANCH = 3'd5,
        NONE = 3'd6
    } case_t;

    case_t dispatch_case;
    logic [1:0] f_dpack_valid;

    always_comb begin
        for(int i = 0; i < `N; i++) begin
            r1[i] = f_d_pack[i].inst.r.rs1;
            r2[i] = f_d_pack[i].inst.r.rs2;
            rd[i] = f_d_pack[i].inst.r.rd;
            f_dpack_valid[i] = f_d_pack[i].valid;
            opa_select[i] = decode_pack[i].opa_select;
            opb_select[i] = decode_pack[i].opb_select;
            has_dest[i] = decode_pack[i].has_dest;
            is_branch[i] = decode_pack[i].cond_branch || decode_pack[i].uncond_branch;
            cond_branch[i]= decode_pack[i].cond_branch;
            halt[i] = decode_pack[i].halt;
            is_load[i] = decode_pack[i].rd_mem;
            is_store[i] = decode_pack[i].wr_mem;
        end
    end

    always_comb begin
        for(int i = 0; i < `N; i++) begin
            dispatch_valid[i] = f_d_pack[i].valid && decode_pack[i].has_dest && (rd[i] != '0); // only request from freelist when we have a destination register to allocate
        end
    end

    always_comb begin
        for (int i = 0; i <`N; i++) begin
            pc_snapshot_out[i]  = (is_branch[i] && f_d_pack[i].valid )? f_d_pack[i].PC : '0;
        end
    end

    always_comb begin
        for (int i = 0; i < `N; i++) begin
            maptable_snapshot_out[i] = snapshot_out[i];
        end
    end

    always_comb begin
        dispatch_num = 0;
        next_branch_count = branch_count;
        dispatch_pack = '{default: '0};
        next_bmask = bmask;
        bmask_idx_0 = 'd0;
        bmask_idx_1 = 'd0;
        branch_encountered = '{default: 1'b0};
        branch_index = '{default: '0};
        
        // Allocate bmask， if there's a mispredict, we can't dispatch in the same cycle.
        if(mispredicted) begin

            next_bmask = mispredicted_bmask & ~mispredicted_bmask_index;//same as resolve
            next_branch_count = $countones(next_bmask);
            dispatch_num = 'd0;

        end else begin
            
            // resolve logic
            if(resolved) begin

                next_bmask = next_bmask & (~resolved_bmask_index);
                next_branch_count = $countones(next_bmask);

            end

            //case define    
            dispatch_case = NONE;  // default

            if (f_d_pack[0].valid && !f_d_pack[1].valid) begin
                if (is_branch[0])
                    dispatch_case = ONE_BRANCH;
                else
                    dispatch_case = ONE_NON_BRANCH;

            end else if (f_d_pack[0].valid && f_d_pack[1].valid) begin
                if (is_branch[0] && is_branch[1])
                    dispatch_case = TWO_BRANCH;
                else if (!is_branch[0] && !is_branch[1])
                    dispatch_case = TWO_NON_BRANCH;
                else if (!is_branch[0] && is_branch[1])
                    dispatch_case = BRANCH_AFTER_NON_BRANCH;
                else
                    dispatch_case = NON_BRANCH_AFTER_BRANCH;
            end
                        
            //dispatch
            case (dispatch_case)
                ONE_BRANCH: begin
                    for(int i = 0; i < 2*`N; i++) begin
                        if(~next_bmask[i]) begin
                            bmask_idx_0[i] = 1'b1;
                            break;
                        end
                    end
                    next_bmask = next_bmask | bmask_idx_0;//update bmask first
                    dispatch_pack[0].inst = f_d_pack[0].inst;
                    dispatch_pack[0].valid = f_d_pack[0].valid;
                    dispatch_pack[0].T    = decode_pack[0].has_dest ? t_new[0] : '0;
                    dispatch_pack[0].Told = decode_pack[0].has_dest ? told[0]  : '0;                 
                    dispatch_pack[0].t1 = t1[0];
                    dispatch_pack[0].t2 = t2[0];
                    dispatch_pack[0].bmask = next_bmask;
                    dispatch_pack[0].bmask_index = bmask_idx_0;
                    dispatch_pack[0].t1_ready = t1_ready[0];
                    dispatch_pack[0].t2_ready = t2_ready[0];
                    dispatch_pack[0].PC = f_d_pack[0].PC;
                    dispatch_pack[0].NPC = f_d_pack[0].NPC;
                    dispatch_pack[0].opa_select = decode_pack[0].opa_select;
                    dispatch_pack[0].opb_select = decode_pack[0].opb_select;
                    dispatch_pack[0].has_dest = decode_pack[0].has_dest && (rd[0] != '0);
                    dispatch_pack[0].alu_func = decode_pack[0].alu_func;
                    dispatch_pack[0].mult = decode_pack[0].mult;
                    dispatch_pack[0].rd_mem = decode_pack[0].rd_mem;
                    dispatch_pack[0].wr_mem = decode_pack[0].wr_mem;
                    dispatch_pack[0].cond_branch = decode_pack[0].cond_branch;
                    dispatch_pack[0].uncond_branch = decode_pack[0].uncond_branch;
                    dispatch_pack[0].csr_op = decode_pack[0].csr_op;
                    dispatch_pack[0].halt = decode_pack[0].halt;
                    dispatch_pack[0].illegal = decode_pack[0].illegal;
                    dispatch_pack[0].predict_addr = f_d_pack[0].predict_addr;
                    dispatch_pack[0].predict_taken = f_d_pack[0].predict_taken;
                    //debug
                    dispatch_pack[0].dest_reg_idx = (has_dest[0])? rd[0]:'0;
                    //send to branch stack
                    branch_encountered[0] = 'd1;
                    branch_encountered[1] = is_branch[1];
                    branch_index[0] = bmask_idx_0;
                    //update branch count
                    next_branch_count = next_branch_count + 1;
                end

                ONE_NON_BRANCH: begin
                    dispatch_pack[0].inst = f_d_pack[0].inst;
                    dispatch_pack[0].valid = f_d_pack[0].valid;
                    dispatch_pack[0].T    = decode_pack[0].has_dest ? t_new[0] : '0;
                    dispatch_pack[0].Told = decode_pack[0].has_dest ? told[0]  : '0;
                    dispatch_pack[0].t1 = t1[0];
                    dispatch_pack[0].t2 = t2[0];
                    dispatch_pack[0].bmask = next_bmask;
                    dispatch_pack[0].bmask_index = 'd0;
                    dispatch_pack[0].t1_ready = t1_ready[0];
                    dispatch_pack[0].t2_ready = t2_ready[0];
                    dispatch_pack[0].PC = f_d_pack[0].PC;
                    dispatch_pack[0].NPC = f_d_pack[0].NPC;
                    dispatch_pack[0].opa_select = decode_pack[0].opa_select;
                    dispatch_pack[0].opb_select = decode_pack[0].opb_select;
                    dispatch_pack[0].has_dest = decode_pack[0].has_dest && (rd[0] != '0);
                    dispatch_pack[0].alu_func = decode_pack[0].alu_func;
                    dispatch_pack[0].mult = decode_pack[0].mult;
                    dispatch_pack[0].rd_mem = decode_pack[0].rd_mem;
                    dispatch_pack[0].wr_mem = decode_pack[0].wr_mem;
                    dispatch_pack[0].cond_branch = 'd0;
                    dispatch_pack[0].uncond_branch = 'd0;
                    dispatch_pack[0].csr_op = decode_pack[0].csr_op;
                    dispatch_pack[0].halt = decode_pack[0].halt;
                    dispatch_pack[0].illegal = decode_pack[0].illegal;
                    dispatch_pack[0].predict_addr = f_d_pack[0].predict_addr;
                    dispatch_pack[0].predict_taken = f_d_pack[0].predict_taken;
                    dispatch_pack[0].sq_index = sq_index_in[0];
                    dispatch_pack[0].lq_index = lq_index_in[0];
                    dispatch_pack[0].sq_valid_mask = sq_valid_mask[0];
                    //debug
                    dispatch_pack[0].dest_reg_idx = (has_dest[0])? rd[0]:'0;
                end

                TWO_BRANCH: begin
                    //inst 0
                    for(int i = 0; i < 2*`N; i++) begin
                        if(~next_bmask[i]) begin
                            bmask_idx_0[i] = 1'b1;
                            break;
                        end
                    end
                    next_bmask = next_bmask | bmask_idx_0;//update bmask first
                    dispatch_pack[0].inst = f_d_pack[0].inst;
                    dispatch_pack[0].valid = f_d_pack[0].valid;
                    dispatch_pack[0].T    = decode_pack[0].has_dest ? t_new[0] : '0;
                    dispatch_pack[0].Told = decode_pack[0].has_dest ? told[0]  : '0;
                    dispatch_pack[0].t1 = t1[0];
                    dispatch_pack[0].t2 = t2[0];
                    dispatch_pack[0].bmask = next_bmask;
                    dispatch_pack[0].bmask_index = bmask_idx_0;
                    dispatch_pack[0].t1_ready = t1_ready[0];
                    dispatch_pack[0].t2_ready = t2_ready[0];
                    dispatch_pack[0].PC = f_d_pack[0].PC;
                    dispatch_pack[0].NPC = f_d_pack[0].NPC;
                    dispatch_pack[0].opa_select = decode_pack[0].opa_select;
                    dispatch_pack[0].opb_select = decode_pack[0].opb_select;
                    dispatch_pack[0].has_dest = decode_pack[0].has_dest && (rd[0] != '0) ;
                    dispatch_pack[0].alu_func = decode_pack[0].alu_func;
                    dispatch_pack[0].mult = decode_pack[0].mult;
                    dispatch_pack[0].rd_mem = decode_pack[0].rd_mem;
                    dispatch_pack[0].wr_mem = decode_pack[0].wr_mem;
                    dispatch_pack[0].cond_branch = decode_pack[0].cond_branch;
                    dispatch_pack[0].uncond_branch = decode_pack[0].uncond_branch;
                    dispatch_pack[0].csr_op = decode_pack[0].csr_op;
                    dispatch_pack[0].halt = decode_pack[0].halt;
                    dispatch_pack[0].illegal = decode_pack[0].illegal;
                    dispatch_pack[0].predict_addr = f_d_pack[0].predict_addr;
                    dispatch_pack[0].predict_taken = f_d_pack[0].predict_taken;
                    //debug
                    dispatch_pack[0].dest_reg_idx = (has_dest[0])? rd[0]:'0;
                    //send to branch stack
                    branch_encountered[0] = 1'b1;
                    branch_index[0] = bmask_idx_0;
                    //inst 1
                    for(int i = 0; i < 2*`N; i++) begin
                        if(~next_bmask[i]) begin
                            bmask_idx_1[i] = 1'b1;
                            break;
                        end
                    end
                    next_bmask = next_bmask | bmask_idx_1;//update bmask first
                    dispatch_pack[1].inst = f_d_pack[1].inst;
                    dispatch_pack[1].valid = f_d_pack[1].valid;
                    dispatch_pack[1].T    = decode_pack[1].has_dest ? t_new[1] : '0;
                    dispatch_pack[1].Told = decode_pack[1].has_dest ? told[1]  : '0;
                    dispatch_pack[1].t1 = t1[1];
                    dispatch_pack[1].t2 = t2[1];
                    dispatch_pack[1].bmask = next_bmask;
                    dispatch_pack[1].bmask_index = bmask_idx_1;
                    dispatch_pack[1].t1_ready = t1_ready[1];
                    dispatch_pack[1].t2_ready = t2_ready[1];
                    dispatch_pack[1].PC = f_d_pack[1].PC;
                    dispatch_pack[1].NPC = f_d_pack[1].NPC;
                    dispatch_pack[1].opa_select = decode_pack[1].opa_select;
                    dispatch_pack[1].opb_select = decode_pack[1].opb_select;
                    dispatch_pack[1].has_dest = decode_pack[1].has_dest && (rd[1] != '0) ;
                    dispatch_pack[1].alu_func = decode_pack[1].alu_func;
                    dispatch_pack[1].mult = decode_pack[1].mult;
                    dispatch_pack[1].rd_mem = decode_pack[1].rd_mem;
                    dispatch_pack[1].wr_mem = decode_pack[1].wr_mem;
                    dispatch_pack[1].cond_branch = decode_pack[1].cond_branch;
                    dispatch_pack[1].uncond_branch = decode_pack[1].uncond_branch;
                    dispatch_pack[1].csr_op = decode_pack[1].csr_op;
                    dispatch_pack[1].halt = decode_pack[1].halt;
                    dispatch_pack[1].illegal = decode_pack[1].illegal;
                    dispatch_pack[1].predict_addr = f_d_pack[1].predict_addr;
                    dispatch_pack[1].predict_taken = f_d_pack[1].predict_taken;
                    //debug
                    dispatch_pack[1].dest_reg_idx = (has_dest[1])? rd[1]:'0;
                    //send to branch stack
                    branch_encountered[1] = 1'b1;
                    branch_index[1] = bmask_idx_1;
                    //update branch count
                    next_branch_count = next_branch_count + 2;
                end

                TWO_NON_BRANCH: begin
                    for(int i = 0; i < `N; i++) begin
                        dispatch_pack[i].inst = f_d_pack[i].inst;
                        dispatch_pack[i].valid = f_d_pack[i].valid;
                        dispatch_pack[i].T    = decode_pack[i].has_dest ? t_new[i] : '0;
                        dispatch_pack[i].Told = decode_pack[i].has_dest ? told[i]  : '0;
                        dispatch_pack[i].t1 = t1[i];
                        dispatch_pack[i].t2 = t2[i];
                        dispatch_pack[i].bmask = next_bmask;
                        dispatch_pack[i].bmask_index = '0;//bmask index only use for branch
                        dispatch_pack[i].t1_ready = t1_ready[i];
                        dispatch_pack[i].t2_ready = t2_ready[i];
                        dispatch_pack[i].PC = f_d_pack[i].PC;
                        dispatch_pack[i].NPC = f_d_pack[i].NPC;
                        dispatch_pack[i].opa_select = decode_pack[i].opa_select;
                        dispatch_pack[i].opb_select = decode_pack[i].opb_select;
                        dispatch_pack[i].has_dest = decode_pack[i].has_dest && (rd[i] != '0);
                        dispatch_pack[i].alu_func = decode_pack[i].alu_func;
                        dispatch_pack[i].mult = decode_pack[i].mult;
                        dispatch_pack[i].rd_mem = decode_pack[i].rd_mem;
                        dispatch_pack[i].wr_mem = decode_pack[i].wr_mem;
                        dispatch_pack[i].cond_branch = 'd0;
                        dispatch_pack[i].uncond_branch = 'd0;
                        dispatch_pack[i].csr_op = decode_pack[i].csr_op;
                        dispatch_pack[i].halt = decode_pack[i].halt;
                        dispatch_pack[i].illegal = decode_pack[i].illegal;
                        dispatch_pack[i].predict_addr = f_d_pack[i].predict_addr;
                        dispatch_pack[i].predict_taken = f_d_pack[i].predict_taken;
                        dispatch_pack[i].sq_index = sq_index_in[i];
                        dispatch_pack[i].lq_index = lq_index_in[i];
                        dispatch_pack[i].sq_valid_mask = sq_valid_mask[i];
                        //debug
                         dispatch_pack[i].dest_reg_idx = (has_dest[i])? rd[i]:'0;
                    end
                end

                BRANCH_AFTER_NON_BRANCH: begin
                    //inst 0 is not branch
                    dispatch_pack[0].inst = f_d_pack[0].inst;
                    dispatch_pack[0].valid = f_d_pack[0].valid;
                    dispatch_pack[0].T    = decode_pack[0].has_dest ? t_new[0] : '0;
                    dispatch_pack[0].Told = decode_pack[0].has_dest ? told[0]  : '0;
                    dispatch_pack[0].t1 = t1[0];
                    dispatch_pack[0].t2 = t2[0];
                    dispatch_pack[0].bmask = next_bmask;
                    dispatch_pack[0].bmask_index = 'd0;
                    dispatch_pack[0].t1_ready = t1_ready[0];
                    dispatch_pack[0].t2_ready = t2_ready[0];
                    dispatch_pack[0].PC = f_d_pack[0].PC;
                    dispatch_pack[0].NPC = f_d_pack[0].NPC;
                    dispatch_pack[0].opa_select = decode_pack[0].opa_select;
                    dispatch_pack[0].opb_select = decode_pack[0].opb_select;
                    dispatch_pack[0].has_dest = decode_pack[0].has_dest && (rd[0] != '0);
                    dispatch_pack[0].alu_func = decode_pack[0].alu_func;
                    dispatch_pack[0].mult = decode_pack[0].mult;
                    dispatch_pack[0].rd_mem = decode_pack[0].rd_mem;
                    dispatch_pack[0].wr_mem = decode_pack[0].wr_mem;
                    dispatch_pack[0].cond_branch = 'd0;
                    dispatch_pack[0].uncond_branch = 'd0;
                    dispatch_pack[0].csr_op = decode_pack[0].csr_op;
                    dispatch_pack[0].halt = decode_pack[0].halt;
                    dispatch_pack[0].illegal = decode_pack[0].illegal;
                    dispatch_pack[0].predict_addr = f_d_pack[0].predict_addr;
                    dispatch_pack[0].predict_taken = f_d_pack[0].predict_taken;
                    dispatch_pack[0].sq_index = sq_index_in[0];
                    dispatch_pack[0].lq_index = lq_index_in[0];
                    dispatch_pack[0].sq_valid_mask = sq_valid_mask[0]; 
                    //debug
                    dispatch_pack[0].dest_reg_idx = (has_dest[0])? rd[0]:'0;              
                    //inst 1 is branch
                    for(int i = 0; i < 2*`N; i++) begin
                        if(~next_bmask[i]) begin
                            bmask_idx_1[i] = 1'b1;
                            break;
                        end
                    end
                    next_bmask = next_bmask | bmask_idx_1;//update bmask first
                    dispatch_pack[1].inst = f_d_pack[1].inst;
                    dispatch_pack[1].valid = f_d_pack[1].valid;
                    dispatch_pack[1].T    = decode_pack[1].has_dest ? t_new[1] : '0;
                    dispatch_pack[1].Told = decode_pack[1].has_dest ? told[1]  : '0;
                    dispatch_pack[1].t1 = t1[1];
                    dispatch_pack[1].t2 = t2[1];
                    dispatch_pack[1].bmask = next_bmask;
                    dispatch_pack[1].bmask_index = bmask_idx_1;
                    dispatch_pack[1].t1_ready = t1_ready[1];
                    dispatch_pack[1].t2_ready = t2_ready[1];
                    dispatch_pack[1].PC = f_d_pack[1].PC;
                    dispatch_pack[1].NPC = f_d_pack[1].NPC;
                    dispatch_pack[1].opa_select = decode_pack[1].opa_select;
                    dispatch_pack[1].opb_select = decode_pack[1].opb_select;
                    dispatch_pack[1].has_dest = decode_pack[1].has_dest && (rd[1] != '0);
                    dispatch_pack[1].alu_func = decode_pack[1].alu_func;
                    dispatch_pack[1].mult = decode_pack[1].mult;
                    dispatch_pack[1].rd_mem = decode_pack[1].rd_mem;
                    dispatch_pack[1].wr_mem = decode_pack[1].wr_mem;
                    dispatch_pack[1].cond_branch = decode_pack[1].cond_branch;
                    dispatch_pack[1].uncond_branch = decode_pack[1].uncond_branch;
                    dispatch_pack[1].csr_op = decode_pack[1].csr_op;
                    dispatch_pack[1].halt = decode_pack[1].halt;
                    dispatch_pack[1].illegal = decode_pack[1].illegal;
                    dispatch_pack[1].predict_addr = f_d_pack[1].predict_addr;
                    dispatch_pack[1].predict_taken = f_d_pack[1].predict_taken;
                    //debug
                    dispatch_pack[1].dest_reg_idx = (has_dest[1])? rd[1]:'0;
                    //send to branch stack
                    branch_encountered[1] = 1'b1;
                    branch_index[1] = bmask_idx_1;
                    //update branch count
                    next_branch_count = next_branch_count + 1;
                end

                NON_BRANCH_AFTER_BRANCH: begin
                    //inst 0 is branch
                    for(int i = 0; i < 2*`N; i++) begin
                        if(~next_bmask[i]) begin
                            bmask_idx_0[i] = 1'b1;
                            break;
                        end
                    end
                    next_bmask = next_bmask | bmask_idx_0;//update bmask first
                    dispatch_pack[0].inst = f_d_pack[0].inst;
                    dispatch_pack[0].valid = f_d_pack[0].valid;
                    dispatch_pack[0].T    = decode_pack[0].has_dest ? t_new[0] : '0;
                    dispatch_pack[0].Told = decode_pack[0].has_dest ? told[0]  : '0;
                    dispatch_pack[0].t1 = t1[0];
                    dispatch_pack[0].t2 = t2[0];
                    dispatch_pack[0].bmask = next_bmask;
                    dispatch_pack[0].bmask_index = bmask_idx_0;
                    dispatch_pack[0].t1_ready = t1_ready[0];
                    dispatch_pack[0].t2_ready = t2_ready[0];
                    dispatch_pack[0].PC = f_d_pack[0].PC;
                    dispatch_pack[0].NPC = f_d_pack[0].NPC;
                    dispatch_pack[0].opa_select = decode_pack[0].opa_select;
                    dispatch_pack[0].opb_select = decode_pack[0].opb_select;
                    dispatch_pack[0].has_dest = decode_pack[0].has_dest && (rd[0] != '0);
                    dispatch_pack[0].alu_func = decode_pack[0].alu_func;
                    dispatch_pack[0].mult = decode_pack[0].mult;
                    dispatch_pack[0].rd_mem = decode_pack[0].rd_mem;
                    dispatch_pack[0].wr_mem = decode_pack[0].wr_mem;
                    dispatch_pack[0].cond_branch = decode_pack[0].cond_branch;
                    dispatch_pack[0].uncond_branch = decode_pack[0].uncond_branch;
                    dispatch_pack[0].csr_op = decode_pack[0].csr_op;
                    dispatch_pack[0].halt = decode_pack[0].halt;
                    dispatch_pack[0].illegal = decode_pack[0].illegal;
                    dispatch_pack[0].predict_addr = f_d_pack[0].predict_addr;
                    dispatch_pack[0].predict_taken = f_d_pack[0].predict_taken;
                    //debug
                    dispatch_pack[0].dest_reg_idx = (has_dest[0])? rd[0]:'0;
                    //send to branch stack
                    branch_encountered[0] = 1'b1;
                    branch_index[0] = bmask_idx_0;

                    //inst 1 is not branch
                    dispatch_pack[1].inst = f_d_pack[1].inst;
                    dispatch_pack[1].valid = f_d_pack[1].valid;
                    dispatch_pack[1].T    = decode_pack[1].has_dest ? t_new[1] : '0;
                    dispatch_pack[1].Told = decode_pack[1].has_dest ? told[1]  : '0;
                    dispatch_pack[1].t1 = t1[1];
                    dispatch_pack[1].t2 = t2[1];
                    dispatch_pack[1].bmask = next_bmask;
                    dispatch_pack[1].bmask_index = 'd0;
                    dispatch_pack[1].t1_ready = t1_ready[1];
                    dispatch_pack[1].t2_ready = t2_ready[1];
                    dispatch_pack[1].PC = f_d_pack[1].PC;
                    dispatch_pack[1].NPC = f_d_pack[1].NPC;
                    dispatch_pack[1].opa_select = decode_pack[1].opa_select;
                    dispatch_pack[1].opb_select = decode_pack[1].opb_select;
                    dispatch_pack[1].has_dest = decode_pack[1].has_dest && (rd[0] != '0);
                    dispatch_pack[1].alu_func = decode_pack[1].alu_func;
                    dispatch_pack[1].mult = decode_pack[1].mult;
                    dispatch_pack[1].rd_mem = decode_pack[1].rd_mem;
                    dispatch_pack[1].wr_mem = decode_pack[1].wr_mem;
                    dispatch_pack[1].cond_branch = 'd0;
                    dispatch_pack[1].uncond_branch = 'd0;
                    dispatch_pack[1].csr_op = decode_pack[1].csr_op;
                    dispatch_pack[1].halt = decode_pack[1].halt;
                    dispatch_pack[1].illegal = decode_pack[1].illegal;
                    dispatch_pack[1].predict_addr = f_d_pack[1].predict_addr;
                    dispatch_pack[1].predict_taken = f_d_pack[1].predict_taken;
                    dispatch_pack[1].sq_index = sq_index_in[1];
                    dispatch_pack[1].lq_index = lq_index_in[1];
                    dispatch_pack[1].sq_valid_mask = sq_valid_mask[1];
                    //debug
                    dispatch_pack[1].dest_reg_idx = (has_dest[1])? rd[1]:'0;
                    //update branch count
                    next_branch_count = next_branch_count + 1;
                end

                NONE:begin
                    dispatch_pack = '{default: '0};
                end

                default: begin
                    dispatch_pack = '{default: '0};
                end

            endcase        
            // Calculate how many instructions we can dispatch in next cycle
            branch_avail_slot = (next_branch_count < 3)? 'd2:(next_branch_count == 3)? 'd1:'d0; 
            small1 = min2(branch_avail_slot,  rs_empty_entries_num);   
            small2 = min2(rob_space_avail,    avail_num);              
            small3 = min2(lq_space_available, sq_space_available);
            small4 = min2(small1, small2);
            small5 = min2(small3, branch_stack_space_avail);                             
            dispatch_num = min2(small4, small5);    
        end
    end

    always_ff @(posedge clock) begin
        if(reset) begin
            bmask <= '0;
            branch_count <= 'd0;
        end else begin
            bmask <= next_bmask;
            branch_count <= next_branch_count;
        end
    end

    maptable maptable0(
        .clock                  (clock),
        .reset                  (reset),
        .mispredicted           (mispredicted),
        .opa_select             (opa_select),
        .opb_select             (opb_select),
        .has_dest               (has_dest),
        .cond_branch            (cond_branch),
        .halt                   (halt),
        .cdb                    (cdb),
        .t_from_freelist        (t_new),
        .rd                     (rd),
        .r1                     (r1),
        .r2                     (r2),
        .snapshot_in            (maptable_snapshot_in),
        .is_branch              (is_branch),
        .valid                  (f_dpack_valid),
        .t1                     (t1),
        .t2                     (t2),
        .told                   (told),
        .t1_ready               (t1_ready),
        .t2_ready               (t2_ready),
        .snapshot_out           (snapshot_out)
    );

endmodule