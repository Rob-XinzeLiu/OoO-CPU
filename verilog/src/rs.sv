`include "sys_defs.svh"

module rs(
    input logic                             clock                               , 
    input logic                             reset                               , 
    //from execute stage
    input logic                             mispredicted                        ,
    input B_MASK                            mispredicted_bmask_index            ,
    input logic                             resolved                            ,
    input B_MASK                            resolved_bmask_index                ,//from execute stage, indicate which branch is resolved
    //from rob
    input ROB_IDX                           rob_index                   [`N-1:0],
    //from dispatch stage
    input D_S_PACKET                        dispatch_pack               [`N-1:0],
    //from sq
    input logic [`SQ_SZ-1:0]                sq_valid_in                         ,
    input logic [`SQ_SZ-1:0]                sq_addr_ready_mask                  ,
    //from cdb
    input X_C_PACKET       [`N-1:0]         cdb                                 ,    
    //etb tag input
    input ETB_TAG_PACKET                    early_tag_bus               [`N-1:0],
    //arbitrate for CDB one cycle earlier
    input logic                             cdb_gnt_alu                 [`N-1:0],
    output logic                            cdb_req_alu                 [`N-1:0],
    //to issue stage
    output D_S_PACKET                       issue_pack                     [5:0], //mult,load,alu,alu,cond_branch,store
    output logic [1:0]                      rs_empty_entries_num                
);

    typedef struct packed{
        logic               busy;             
        INST                inst;
        ADDR                PC;
        ADDR                NPC;
        ALU_OPA_SELECT      opa_select;
        ALU_OPB_SELECT      opb_select;
        logic               has_dest;
        ALU_FUNC            alu_func;
        logic               mult;
        logic               rd_mem;
        logic               wr_mem;
        logic               cond_branch;
        logic               uncond_branch;
        logic               csr_op;
        logic               halt;
        logic               illegal;
        B_MASK              bmask;          
        B_MASK              bmask_index;    //which bit of bmask is for this branch
        PRF_IDX             T;
        PRF_IDX             t1;
        PRF_IDX             t2;
        logic               t1_ready;
        logic               t2_ready;
        ROB_IDX             rob_index;
        logic               predict_taken;
        ADDR                predict_addr;
        LQ_IDX              lq_index;
        SQ_IDX              sq_index;
        logic [`SQ_SZ-1:0]  sq_valid_mask;
        CTYPE               c_type;
        logic [1:0]         current_head;
        logic [2:0]         current_count;
        
    } RS_ENTRY;

    RS_ENTRY rs_entry       [`RS_SZ-1:0];
    RS_ENTRY next_rs_entry  [`RS_SZ-1:0];
    RS_ENTRY internal_rs_entry  [`RS_SZ-1:0];

    logic [`RS_SZ-1:0]      ready_entry_mask;
    logic [`RS_SZ-1:0]      issue_mask;
    logic [`RS_SZ-1:0]      mult_issue_mask;
    logic [`RS_SZ-1:0]      empty_entry_mask, next_empty_entry_mask;//
    logic [`RS_SZ-1:0]      dispatch_mask;

    logic [`RS_SZ-1:0]      load_mask, load_issue_mask;
    logic [`RS_SZ-1:0]      store_mask, store_issue_mask;

    logic [`RS_SZ-1:0]      mult_mask;//, next_mult_mask;
    logic [`RS_SZ-1:0]      cond_branch_mask;
    logic [`RS_SZ-1:0]      cond_branch_issue_mask;

    logic [`N-1:0] [`RS_SZ-1:0]      dispatch_bus;
    logic [`N-1:0] [`RS_SZ-1:0]      issue_bus;
    logic                   empty_dispatch, empty_issue, empty_mult_issue, no_gnt, empty_cond_branch_issue, empty_load_issue, empty_store_issue;

    psel_gen #(.WIDTH(`RS_SZ), .REQS(`N)) priorty_selector_dispatch(
        .req(empty_entry_mask),
        .gnt(dispatch_mask),
        .gnt_bus(dispatch_bus),
        .empty(empty_dispatch)
    );

    psel_gen #(.WIDTH(`RS_SZ), .REQS('d1)) priorty_selector_issue_mult(
        .req(mult_mask),
        .gnt(mult_issue_mask),
        .gnt_bus(),
        .empty(empty_mult_issue)
    );

    psel_gen #(.WIDTH(`RS_SZ), .REQS(`N)) priorty_selector_issue(
        .req(ready_entry_mask),
        .gnt(issue_mask),
        .gnt_bus(issue_bus),
        .empty(empty_issue)
    );

    psel_gen #(.WIDTH(`RS_SZ), .REQS('d1)) priorty_selector_cond_branch(
        .req(cond_branch_mask),
        .gnt(cond_branch_issue_mask),
        .gnt_bus(),
        .empty(empty_cond_branch_issue)
    );

    psel_gen #(.WIDTH(`RS_SZ), .REQS('d1)) priorty_selector_load(
        .req(load_mask),
        .gnt(load_issue_mask),
        .gnt_bus(),
        .empty(empty_load_issue)
    );

    psel_gen #(.WIDTH(`RS_SZ), .REQS('d1)) priorty_selector_store(
        .req(store_mask),
        .gnt(store_issue_mask),
        .gnt_bus(),
        .empty(empty_store_issue)
    );

    typedef enum logic [3:0] {
        ISSUE_1_MULT_1_ALU,
        ISSUE_1_MULT_1_LOAD,
        ISSUE_1_MULT,
        ISSUE_1_LOAD,
        ISSUE_1_LOAD_1_ALU,
        ISSUE_2_ALU,
        ISSUE_1_ALU,
        ISSUE_NOTHING
    } case_t;
    
    case_t issue_case;

    // candidate existence (do NOT depend on gnt)
    logic has_ready_mult, has_ready_load;
    logic cand_alu0, cand_alu1;   // selected candidates by psel_gen
    logic any_gnt, two_gnt;
    logic t1_hit, t2_hit;

    logic dispatch_1, dispatch_2;
    assign dispatch_1 = (dispatch_pack[0].valid && !dispatch_pack[1].valid);
    assign dispatch_2 = (dispatch_pack[0].valid && dispatch_pack[1].valid);

    always_comb begin
        //default
        next_rs_entry = rs_entry;
        internal_rs_entry = rs_entry;
        empty_entry_mask = '0;
        ready_entry_mask = '0;
        issue_pack = '{default:'0};
        mult_mask = '0;
        cdb_req_alu = '{default:'0};
        cond_branch_mask =  '0;
        rs_empty_entries_num  = '0;
        t1_hit = '0;
        t2_hit = '0;

        for (int i = 0; i< `RS_SZ; i++)begin
            empty_entry_mask[i] = !rs_entry[i].busy;
        end

        //enqueue logic
        if(dispatch_1 && !mispredicted )begin
            for (int i=0; i<`RS_SZ; i++) begin
                if(dispatch_bus[0][i] ) begin
                    //from dispatch pack 0
                    next_rs_entry[i].inst= dispatch_pack[0].inst;
                    next_rs_entry[i].PC= dispatch_pack[0].PC;
                    next_rs_entry[i].NPC= dispatch_pack[0].NPC;
                    next_rs_entry[i].opa_select= dispatch_pack[0].opa_select;
                    next_rs_entry[i].opb_select= dispatch_pack[0].opb_select;
                    next_rs_entry[i].has_dest= dispatch_pack[0].has_dest;
                    next_rs_entry[i].alu_func= dispatch_pack[0].alu_func;
                    next_rs_entry[i].mult= dispatch_pack[0].mult;
                    next_rs_entry[i].rd_mem= dispatch_pack[0].rd_mem;
                    next_rs_entry[i].wr_mem= dispatch_pack[0].wr_mem;
                    next_rs_entry[i].cond_branch= dispatch_pack[0].cond_branch;
                    next_rs_entry[i].uncond_branch= dispatch_pack[0].uncond_branch;
                    next_rs_entry[i].csr_op= dispatch_pack[0].csr_op;
                    next_rs_entry[i].halt= dispatch_pack[0].halt;
                    next_rs_entry[i].illegal= dispatch_pack[0].illegal;
                    next_rs_entry[i].bmask= dispatch_pack[0].bmask;
                    next_rs_entry[i].bmask_index= dispatch_pack[0].bmask_index;
                    next_rs_entry[i].T= dispatch_pack[0].T;
                    next_rs_entry[i].t1= dispatch_pack[0].t1;
                    next_rs_entry[i].t2= dispatch_pack[0].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[0].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[0].t2_ready;
                    next_rs_entry[i].predict_addr = dispatch_pack[0].predict_addr;
                    next_rs_entry[i].predict_taken = dispatch_pack[0].predict_taken;
                    next_rs_entry[i].lq_index = dispatch_pack[0].lq_index;
                    next_rs_entry[i].sq_index = dispatch_pack[0].sq_index;
                    next_rs_entry[i].sq_valid_mask = dispatch_pack[0].sq_valid_mask;
                    next_rs_entry[i].busy = 1;
                    next_rs_entry[i].c_type = dispatch_pack[0].c_type;
                    next_rs_entry[i].current_count = dispatch_pack[0].current_count;
                    next_rs_entry[i].current_head = dispatch_pack[0].current_head;

                    //from rob
                    next_rs_entry[i].rob_index = rob_index[0];
                end
            end
        end

        if(dispatch_2 && !mispredicted )begin
            for (int i=0; i<`RS_SZ; i++) begin
                if(dispatch_bus[0][i] ) begin
                    //from dispatch pack 0
                    next_rs_entry[i].inst= dispatch_pack[0].inst;
                    next_rs_entry[i].PC= dispatch_pack[0].PC;
                    next_rs_entry[i].NPC= dispatch_pack[0].NPC;
                    next_rs_entry[i].opa_select= dispatch_pack[0].opa_select;
                    next_rs_entry[i].opb_select= dispatch_pack[0].opb_select;
                    next_rs_entry[i].has_dest= dispatch_pack[0].has_dest;
                    next_rs_entry[i].alu_func= dispatch_pack[0].alu_func;
                    next_rs_entry[i].mult= dispatch_pack[0].mult;
                    next_rs_entry[i].rd_mem= dispatch_pack[0].rd_mem;
                    next_rs_entry[i].wr_mem= dispatch_pack[0].wr_mem;
                    next_rs_entry[i].cond_branch= dispatch_pack[0].cond_branch;
                    next_rs_entry[i].uncond_branch= dispatch_pack[0].uncond_branch;
                    next_rs_entry[i].csr_op= dispatch_pack[0].csr_op;
                    next_rs_entry[i].halt= dispatch_pack[0].halt;
                    next_rs_entry[i].illegal= dispatch_pack[0].illegal;
                    next_rs_entry[i].bmask= dispatch_pack[0].bmask;
                    next_rs_entry[i].bmask_index= dispatch_pack[0].bmask_index;
                    next_rs_entry[i].T= dispatch_pack[0].T;
                    next_rs_entry[i].t1= dispatch_pack[0].t1;
                    next_rs_entry[i].t2= dispatch_pack[0].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[0].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[0].t2_ready;
                    next_rs_entry[i].predict_addr = dispatch_pack[0].predict_addr;
                    next_rs_entry[i].predict_taken = dispatch_pack[0].predict_taken;
                    next_rs_entry[i].lq_index = dispatch_pack[0].lq_index;
                    next_rs_entry[i].sq_index = dispatch_pack[0].sq_index;
                    next_rs_entry[i].sq_valid_mask = dispatch_pack[0].sq_valid_mask;
                    next_rs_entry[i].busy = 1;
                    next_rs_entry[i].c_type = dispatch_pack[0].c_type;
                    next_rs_entry[i].current_count = dispatch_pack[0].current_count;
                    next_rs_entry[i].current_head = dispatch_pack[0].current_head;

                    //from rob
                    next_rs_entry[i].rob_index = rob_index[0];
                end
            end
            for (int i=0; i<`RS_SZ; i++) begin
                if(dispatch_bus[1][i] ) begin
                    //from dispatch pack 1
                    next_rs_entry[i].inst= dispatch_pack[1].inst;
                    next_rs_entry[i].PC= dispatch_pack[1].PC;
                    next_rs_entry[i].NPC= dispatch_pack[1].NPC;
                    next_rs_entry[i].opa_select= dispatch_pack[1].opa_select;
                    next_rs_entry[i].opb_select= dispatch_pack[1].opb_select;
                    next_rs_entry[i].has_dest= dispatch_pack[1].has_dest;
                    next_rs_entry[i].alu_func= dispatch_pack[1].alu_func;
                    next_rs_entry[i].mult= dispatch_pack[1].mult;
                    next_rs_entry[i].rd_mem= dispatch_pack[1].rd_mem;
                    next_rs_entry[i].wr_mem= dispatch_pack[1].wr_mem;
                    next_rs_entry[i].cond_branch= dispatch_pack[1].cond_branch;
                    next_rs_entry[i].uncond_branch= dispatch_pack[1].uncond_branch;
                    next_rs_entry[i].csr_op= dispatch_pack[1].csr_op;
                    next_rs_entry[i].halt= dispatch_pack[1].halt;
                    next_rs_entry[i].illegal= dispatch_pack[1].illegal;
                    next_rs_entry[i].bmask_index= dispatch_pack[1].bmask_index;
                    next_rs_entry[i].bmask= dispatch_pack[1].bmask;
                    next_rs_entry[i].T= dispatch_pack[1].T;
                    next_rs_entry[i].t1= dispatch_pack[1].t1;
                    next_rs_entry[i].t2= dispatch_pack[1].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[1].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[1].t2_ready;
                    next_rs_entry[i].predict_addr = dispatch_pack[1].predict_addr;
                    next_rs_entry[i].predict_taken = dispatch_pack[1].predict_taken;
                    next_rs_entry[i].lq_index = dispatch_pack[1].lq_index;
                    next_rs_entry[i].sq_index = dispatch_pack[1].sq_index;
                    next_rs_entry[i].sq_valid_mask = dispatch_pack[1].sq_valid_mask;
                    next_rs_entry[i].busy = 1;
                    next_rs_entry[i].c_type = dispatch_pack[1].c_type;
                    next_rs_entry[i].current_count = dispatch_pack[1].current_count;
                    next_rs_entry[i].current_head = dispatch_pack[1].current_head;
                    //from rob
                    next_rs_entry[i].rob_index = rob_index[1];
                end
            end
        end

        //resolve logic
        if (resolved) begin
            for (int j = 0; j < `RS_SZ; j++) begin
                if (rs_entry[j].busy) begin
                    internal_rs_entry[j].bmask = rs_entry[j].bmask & ~(resolved_bmask_index);
                end
                if(next_rs_entry[j].busy) begin
                    next_rs_entry[j].bmask = next_rs_entry[j].bmask & ~(resolved_bmask_index);
                end
            end
        end
        
        //mispredict logic
        if(mispredicted) begin
            for (int i = 0; i < `RS_SZ; i++)begin
                if(rs_entry[i].busy && (mispredicted_bmask_index & rs_entry[i].bmask)) begin
                    internal_rs_entry[i] = '0;
                end
                if(next_rs_entry[i].busy && (mispredicted_bmask_index & next_rs_entry[i].bmask)) begin
                    next_rs_entry[i] = '0;
                end
            end
        end

        // unified wakeup (ETB + CDB) + build ready masks
        for (int j = 0; j < `RS_SZ; j++) begin
            // match against next_rs_entry so same-cycle dispatch is visible
            t1_hit =
                (early_tag_bus[0].valid && (internal_rs_entry[j].t1 == early_tag_bus[0].tag)) ||
                (early_tag_bus[1].valid && (internal_rs_entry[j].t1 == early_tag_bus[1].tag)) ||
                (cdb[0].valid          && (internal_rs_entry[j].t1 == cdb[0].complete_tag))   ||
                (cdb[1].valid          && (internal_rs_entry[j].t1 == cdb[1].complete_tag));

            t2_hit =
                (early_tag_bus[0].valid && (internal_rs_entry[j].t2 == early_tag_bus[0].tag)) ||
                (early_tag_bus[1].valid && (internal_rs_entry[j].t2 == early_tag_bus[1].tag)) ||
                (cdb[0].valid          && (internal_rs_entry[j].t2 == cdb[0].complete_tag))   ||
                (cdb[1].valid          && (internal_rs_entry[j].t2 == cdb[1].complete_tag));

            // persist readiness into entry (important for ETB 1-cycle pulse)
            if (internal_rs_entry[j].busy) begin
                if (t1_hit) begin
                    internal_rs_entry[j].t1_ready = 1'b1;
                    next_rs_entry[j].t1_ready = 1'b1;
                end
                if (t2_hit) begin
                    internal_rs_entry[j].t2_ready = 1'b1;
                    next_rs_entry[j].t2_ready = 1'b1;
                end
            end

            // now compute masks from UPDATED readiness
            mult_mask[j] =
                internal_rs_entry[j].busy &&
                internal_rs_entry[j].t1_ready &&
                internal_rs_entry[j].t2_ready &&
                internal_rs_entry[j].mult;

            ready_entry_mask[j] =
                internal_rs_entry[j].busy &&
                internal_rs_entry[j].t1_ready &&
                internal_rs_entry[j].t2_ready &&
                !internal_rs_entry[j].mult &&
                !internal_rs_entry[j].rd_mem &&
                !internal_rs_entry[j].wr_mem &&
                !internal_rs_entry[j].cond_branch;

            cond_branch_mask[j] =
                internal_rs_entry[j].busy &&
                internal_rs_entry[j].t1_ready &&
                internal_rs_entry[j].t2_ready &&
                internal_rs_entry[j].cond_branch;

            store_mask[j] =
                internal_rs_entry[j].busy &&
                internal_rs_entry[j].t1_ready &&
                internal_rs_entry[j].t2_ready &&
                internal_rs_entry[j].wr_mem;

            load_mask[j] =
                internal_rs_entry[j].busy &&
                internal_rs_entry[j].t1_ready &&
                internal_rs_entry[j].t2_ready &&
                internal_rs_entry[j].rd_mem &&
                !(|(internal_rs_entry[j].sq_valid_mask & sq_valid_in & ~sq_addr_ready_mask));//all the older store's address is known
                //need to consider retired sq entry, so we also input current sq valid
        end



        has_ready_mult = |mult_mask;
        has_ready_load = |load_mask;

        // these come from the priority selector outputs
        cand_alu0 = |issue_bus[0];    // first ALU candidate exists
        cand_alu1 = |issue_bus[1];    // second ALU candidate exists

        if (cand_alu0) cdb_req_alu[0] = 1'b1;
        if (cand_alu1) cdb_req_alu[1] = 1'b1;

        // use gnt to decide how many ALUs can truly issue this cycle
        no_gnt = !(cdb_gnt_alu[0] || cdb_gnt_alu[1]);
        two_gnt = cdb_gnt_alu[0] && cdb_gnt_alu[1];

        // issue_case: mult prioritized, but ALU participation depends on gnt
        issue_case =
            (has_ready_mult && has_ready_load)  ? ISSUE_1_MULT_1_LOAD  :
            (has_ready_mult && cdb_gnt_alu[0])  ? ISSUE_1_MULT_1_ALU   :
            (has_ready_mult)                    ? ISSUE_1_MULT         :
            (has_ready_load && cdb_gnt_alu[0])  ? ISSUE_1_LOAD_1_ALU   :
            (has_ready_load)                    ? ISSUE_1_LOAD         :
            (two_gnt)                           ? ISSUE_2_ALU          :
            (cdb_gnt_alu[0])                    ? ISSUE_1_ALU          : ISSUE_NOTHING;

        // Case 1: Both mult and non-mult instructions are ready
        // Issue mult to pack[0], load to pack[1]
        case(issue_case)
            ISSUE_1_MULT_1_LOAD: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(mult_issue_mask[i]) begin
                        //to issue pack 0
                        issue_pack[0].valid= 'b1;
                        issue_pack[0].inst= internal_rs_entry[i].inst;
                        issue_pack[0].PC= internal_rs_entry[i].PC;
                        issue_pack[0].NPC= internal_rs_entry[i].NPC;
                        issue_pack[0].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[0].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[0].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[0].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[0].mult= internal_rs_entry[i].mult;
                        issue_pack[0].cond_branch= internal_rs_entry[i].cond_branch;
                        issue_pack[0].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[0].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[0].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[0].bmask= internal_rs_entry[i].bmask;
                        issue_pack[0].T= internal_rs_entry[i].T;
                        issue_pack[0].t1= internal_rs_entry[i].t1;
                        issue_pack[0].t2= internal_rs_entry[i].t2;
                        issue_pack[0].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[0].predict_taken = internal_rs_entry[i].predict_taken;
                        issue_pack[0].predict_addr = internal_rs_entry[i].predict_addr;
                        issue_pack[0].lq_index = internal_rs_entry[i].lq_index;
                        issue_pack[0].sq_index = internal_rs_entry[i].sq_index;

                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end

                    if(load_issue_mask[i])begin
                        issue_pack[1].valid= 'b1;
                        issue_pack[1].inst= internal_rs_entry[i].inst;
                        issue_pack[1].PC= internal_rs_entry[i].PC;
                        issue_pack[1].NPC= internal_rs_entry[i].NPC;
                        issue_pack[1].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[1].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[1].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[1].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[1].mult= internal_rs_entry[i].mult;
                        issue_pack[1].rd_mem= internal_rs_entry[i].rd_mem;
                        issue_pack[1].wr_mem= internal_rs_entry[i].wr_mem;
                        issue_pack[1].cond_branch= internal_rs_entry[i].cond_branch;
                        issue_pack[1].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[1].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[1].halt= internal_rs_entry[i].halt;
                        issue_pack[1].illegal= internal_rs_entry[i].illegal;
                        issue_pack[1].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[1].bmask= internal_rs_entry[i].bmask;
                        issue_pack[1].T= internal_rs_entry[i].T;
                        issue_pack[1].t1= internal_rs_entry[i].t1;
                        issue_pack[1].t2= internal_rs_entry[i].t2;
                        issue_pack[1].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[1].lq_index = internal_rs_entry[i].lq_index;

                    end

                end
            end

            //Issue mult to pack[0], non-mult to pack[1]
            ISSUE_1_MULT_1_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(mult_issue_mask[i]) begin
                        //to issue pack 0
                        issue_pack[0].valid= 'b1;
                        issue_pack[0].inst= internal_rs_entry[i].inst;
                        issue_pack[0].PC= internal_rs_entry[i].PC;
                        issue_pack[0].NPC= internal_rs_entry[i].NPC;
                        issue_pack[0].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[0].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[0].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[0].mult= internal_rs_entry[i].mult;
                        issue_pack[0].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[0].bmask= internal_rs_entry[i].bmask;
                        issue_pack[0].T= internal_rs_entry[i].T;
                        issue_pack[0].t1= internal_rs_entry[i].t1;
                        issue_pack[0].t2= internal_rs_entry[i].t2;
                        issue_pack[0].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[0].c_type = internal_rs_entry[i].c_type;
                        issue_pack[0].current_count = internal_rs_entry[i].current_count;
                        issue_pack[0].current_head = internal_rs_entry[i].current_head;

                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                    if(issue_bus[0][i] && cdb_gnt_alu[0] ) begin
                        //to issue pack 1
                        issue_pack[2].valid= 'b1;
                        issue_pack[2].inst= internal_rs_entry[i].inst;
                        issue_pack[2].PC= internal_rs_entry[i].PC;
                        issue_pack[2].NPC= internal_rs_entry[i].NPC;
                        issue_pack[2].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[2].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[2].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[2].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[2].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[2].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[2].halt= internal_rs_entry[i].halt;
                        issue_pack[2].illegal= internal_rs_entry[i].illegal;
                        issue_pack[2].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[2].bmask= internal_rs_entry[i].bmask;
                        issue_pack[2].T= internal_rs_entry[i].T;
                        issue_pack[2].t1= internal_rs_entry[i].t1;
                        issue_pack[2].t2= internal_rs_entry[i].t2;
                        issue_pack[2].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[2].c_type = internal_rs_entry[i].c_type;
                        issue_pack[2].current_count = internal_rs_entry[i].current_count;
                        issue_pack[2].current_head = internal_rs_entry[i].current_head;
                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end 
                end
            end

            ISSUE_1_MULT: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(mult_issue_mask[i]) begin
                        //to issue pack 0
                        issue_pack[0].valid = 'b1;
                        issue_pack[0].inst= internal_rs_entry[i].inst;
                        issue_pack[0].PC= internal_rs_entry[i].PC;
                        issue_pack[0].NPC= internal_rs_entry[i].NPC;
                        issue_pack[0].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[0].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[0].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[0].mult= internal_rs_entry[i].mult;
                        issue_pack[0].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[0].bmask= internal_rs_entry[i].bmask;
                        issue_pack[0].T= internal_rs_entry[i].T;
                        issue_pack[0].t1= internal_rs_entry[i].t1;
                        issue_pack[0].t2= internal_rs_entry[i].t2;
                        issue_pack[0].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[0].c_type = internal_rs_entry[i].c_type;
                        issue_pack[0].current_count = internal_rs_entry[i].current_count;
                        issue_pack[0].current_head = internal_rs_entry[i].current_head;
                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                end
            end

            ISSUE_1_LOAD_1_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(load_issue_mask[i]) begin
                        //to issue pack 1
                        issue_pack[1].valid= 'b1;
                        issue_pack[1].inst= internal_rs_entry[i].inst;
                        issue_pack[1].PC= internal_rs_entry[i].PC;
                        issue_pack[1].NPC= internal_rs_entry[i].NPC;
                        issue_pack[1].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[1].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[1].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[1].rd_mem= internal_rs_entry[i].rd_mem;
                        issue_pack[1].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[1].bmask= internal_rs_entry[i].bmask;
                        issue_pack[1].T= internal_rs_entry[i].T;
                        issue_pack[1].t1= internal_rs_entry[i].t1;
                        issue_pack[1].t2= internal_rs_entry[i].t2;
                        issue_pack[1].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[1].lq_index = internal_rs_entry[i].lq_index;

                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                    if(issue_bus[0][i] && cdb_gnt_alu[0] ) begin
                        //to issue pack 1
                        issue_pack[2].valid= 'b1;
                        issue_pack[2].inst= internal_rs_entry[i].inst;
                        issue_pack[2].PC= internal_rs_entry[i].PC;
                        issue_pack[2].NPC= internal_rs_entry[i].NPC;
                        issue_pack[2].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[2].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[2].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[2].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[2].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[2].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[2].halt= internal_rs_entry[i].halt;
                        issue_pack[2].illegal= internal_rs_entry[i].illegal;
                        issue_pack[2].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[2].bmask= internal_rs_entry[i].bmask;
                        issue_pack[2].T= internal_rs_entry[i].T;
                        issue_pack[2].t1= internal_rs_entry[i].t1;
                        issue_pack[2].t2= internal_rs_entry[i].t2;
                        issue_pack[2].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[2].c_type = internal_rs_entry[i].c_type;
                        issue_pack[2].current_count = internal_rs_entry[i].current_count;
                        issue_pack[2].current_head = internal_rs_entry[i].current_head;
                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end 
                end
            end

            ISSUE_1_LOAD: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(load_issue_mask[i]) begin
                        //to issue pack 1
                        issue_pack[1].valid= 'b1;
                        issue_pack[1].inst= internal_rs_entry[i].inst;
                        issue_pack[1].PC= internal_rs_entry[i].PC;
                        issue_pack[1].NPC= internal_rs_entry[i].NPC;
                        issue_pack[1].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[1].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[1].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[1].rd_mem= internal_rs_entry[i].rd_mem;
                        issue_pack[1].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[1].bmask= internal_rs_entry[i].bmask;
                        issue_pack[1].T= internal_rs_entry[i].T;
                        issue_pack[1].t1= internal_rs_entry[i].t1;
                        issue_pack[1].t2= internal_rs_entry[i].t2;
                        issue_pack[1].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[1].lq_index = internal_rs_entry[i].lq_index;

                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                end
            end


            // Case 3: Only non-mult instructions are ready (no mult or mult not ready)
            // Issue 2 non-mult instructions
            ISSUE_2_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(issue_bus[0][i] && cdb_gnt_alu[0]) begin
                        //to issue pack 0
                        issue_pack[2].valid = 'b1;
                        issue_pack[2].inst= internal_rs_entry[i].inst;
                        issue_pack[2].PC= internal_rs_entry[i].PC;
                        issue_pack[2].NPC= internal_rs_entry[i].NPC;
                        issue_pack[2].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[2].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[2].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[2].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[2].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[2].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[2].halt= internal_rs_entry[i].halt;
                        issue_pack[2].illegal= internal_rs_entry[i].illegal;
                        issue_pack[2].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[2].bmask= internal_rs_entry[i].bmask;
                        issue_pack[2].T= internal_rs_entry[i].T;
                        issue_pack[2].t1= internal_rs_entry[i].t1;
                        issue_pack[2].t2= internal_rs_entry[i].t2;
                        issue_pack[2].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[2].c_type = internal_rs_entry[i].c_type;
                        issue_pack[2].current_count = internal_rs_entry[i].current_count;
                        issue_pack[2].current_head = internal_rs_entry[i].current_head;

                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                    if(issue_bus[1][i] && cdb_gnt_alu[1]) begin
                        //to issue pack 1
                        issue_pack[3].valid = 'b1;
                        issue_pack[3].inst= internal_rs_entry[i].inst;
                        issue_pack[3].PC= internal_rs_entry[i].PC;
                        issue_pack[3].NPC= internal_rs_entry[i].NPC;
                        issue_pack[3].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[3].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[3].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[3].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[3].mult= internal_rs_entry[i].mult;
                        issue_pack[3].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[3].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[3].halt= internal_rs_entry[i].halt;
                        issue_pack[3].illegal= internal_rs_entry[i].illegal;
                        issue_pack[3].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[3].bmask= internal_rs_entry[i].bmask;
                        issue_pack[3].T= internal_rs_entry[i].T;
                        issue_pack[3].t1= internal_rs_entry[i].t1;
                        issue_pack[3].t2= internal_rs_entry[i].t2;
                        issue_pack[3].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[3].c_type = internal_rs_entry[i].c_type;
                        issue_pack[3].current_count = internal_rs_entry[i].current_count;
                        issue_pack[3].current_head = internal_rs_entry[i].current_head;
                    
                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                end
            end
            //case4: only 1 non-mult instruction is ready
            ISSUE_1_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(issue_bus[0][i] && cdb_gnt_alu[0]) begin
                        //to issue pack 0
                        issue_pack[2].valid= 'b1;
                        issue_pack[2].inst= internal_rs_entry[i].inst;
                        issue_pack[2].PC= internal_rs_entry[i].PC;
                        issue_pack[2].NPC= internal_rs_entry[i].NPC;
                        issue_pack[2].opa_select= internal_rs_entry[i].opa_select;
                        issue_pack[2].opb_select= internal_rs_entry[i].opb_select;
                        issue_pack[2].has_dest= internal_rs_entry[i].has_dest;
                        issue_pack[2].alu_func= internal_rs_entry[i].alu_func;
                        issue_pack[2].uncond_branch= internal_rs_entry[i].uncond_branch;
                        issue_pack[2].csr_op= internal_rs_entry[i].csr_op;
                        issue_pack[2].halt= internal_rs_entry[i].halt;
                        issue_pack[2].illegal= internal_rs_entry[i].illegal;
                        issue_pack[2].bmask_index= internal_rs_entry[i].bmask_index;
                        issue_pack[2].bmask= internal_rs_entry[i].bmask;
                        issue_pack[2].T= internal_rs_entry[i].T;
                        issue_pack[2].t1= internal_rs_entry[i].t1;
                        issue_pack[2].t2= internal_rs_entry[i].t2;
                        issue_pack[2].rob_index = internal_rs_entry[i].rob_index;
                        issue_pack[2].c_type = internal_rs_entry[i].c_type;
                        issue_pack[2].current_count = internal_rs_entry[i].current_count;
                        issue_pack[2].current_head = internal_rs_entry[i].current_head;
                        //mark as not busy
                        next_rs_entry[i] = '0;
                    end
                end
            end
            //case5: no instruction is ready
            ISSUE_NOTHING: begin
                issue_pack[0].valid = 'b0;
                issue_pack[1].valid = 'b0;
                issue_pack[2].valid = 'b0;
                issue_pack[3].valid = 'b0;
            end
            default:begin
                issue_pack[0].valid = 'b0;
                issue_pack[1].valid = 'b0;
                issue_pack[2].valid = 'b0;
                issue_pack[3].valid = 'b0;
            end
        endcase

        //issue conditional branch if any
        if(!empty_cond_branch_issue) begin
            for (int i = 0; i<`RS_SZ; i++)begin
                if(cond_branch_issue_mask[i]) begin
                    issue_pack[4].valid= 'b1;
                    issue_pack[4].inst= internal_rs_entry[i].inst;
                    issue_pack[4].PC= internal_rs_entry[i].PC;
                    issue_pack[4].NPC= internal_rs_entry[i].NPC;
                    issue_pack[4].opa_select= internal_rs_entry[i].opa_select;
                    issue_pack[4].opb_select= internal_rs_entry[i].opb_select;
                    issue_pack[4].cond_branch= internal_rs_entry[i].cond_branch;
                    issue_pack[4].csr_op= internal_rs_entry[i].csr_op;
                    issue_pack[4].bmask_index= internal_rs_entry[i].bmask_index;
                    issue_pack[4].bmask= internal_rs_entry[i].bmask;
                    issue_pack[4].t1= internal_rs_entry[i].t1;
                    issue_pack[4].t2= internal_rs_entry[i].t2;
                    issue_pack[4].rob_index = internal_rs_entry[i].rob_index;
                    issue_pack[4].c_type = internal_rs_entry[i].c_type;
                    issue_pack[4].current_count = internal_rs_entry[i].current_count;
                    issue_pack[4].current_head = internal_rs_entry[i].current_head;
                    //mark as not busy
                    next_rs_entry[i] = '0;
                end
            end
        end

        //issue store if any
        if(!empty_store_issue) begin
            for (int i = 0; i<`RS_SZ; i++)begin
                if(store_issue_mask[i]) begin
                    issue_pack[5].valid= 'b1;
                    issue_pack[5].inst= internal_rs_entry[i].inst;
                    issue_pack[5].PC= internal_rs_entry[i].PC;
                    issue_pack[5].NPC= internal_rs_entry[i].NPC;
                    issue_pack[5].opa_select= internal_rs_entry[i].opa_select;
                    issue_pack[5].opb_select= internal_rs_entry[i].opb_select;
                    issue_pack[5].wr_mem= internal_rs_entry[i].wr_mem;
                    issue_pack[5].csr_op= internal_rs_entry[i].csr_op;
                    issue_pack[5].bmask= internal_rs_entry[i].bmask;
                    issue_pack[5].t1= internal_rs_entry[i].t1;
                    issue_pack[5].t2= internal_rs_entry[i].t2;
                    issue_pack[5].rob_index = internal_rs_entry[i].rob_index;
                    issue_pack[5].sq_index = internal_rs_entry[i].sq_index;
                    //mark as not busy
                    next_rs_entry[i] = '0;
                end
            end
        end


        for(int i = 0; i< `RS_SZ; i++)begin
            if(!next_rs_entry[i].busy) begin
                rs_empty_entries_num  = rs_empty_entries_num  + 1;
                if(rs_empty_entries_num == 2) begin
                    break;
                end
            end
        end

    end


    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////       sequential logic  ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    always_ff @(posedge clock)begin
        if(reset)begin
            rs_entry <= '{default: '0};
        end
        else begin
            rs_entry <= next_rs_entry;
        end
    end

endmodule