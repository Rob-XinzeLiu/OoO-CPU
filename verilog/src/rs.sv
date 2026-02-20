`include "sys_defs.svh"

module rs(
    input logic                         clock                               , 
    input logic                         reset                               , 
    input logic                         mispredicted                        ,//from execute stage
    input B_MASK                        mispredicted_bmask_index            ,//from execute stage
    input ROB_IDX                       rob_index                   [`N-1:0],//from rob
    input logic [1:0]                   dispatch_num                        , //number of instructions dispatched in this cycle
    input D_S_PACKET                    dispatch_pack               [`N-1:0],//from dispatcher
    input X_C_PACKET                    cdb                         [`N-1:0],  
    input logic                         resolved                            ,
    input B_MASK                        resolved_bmask_index                ,//from execute stage, indicate which branch is resolved
    input logic                         alu0_ready                          ,
    input logic                         alu1_ready                          ,
  
    output D_S_PACKET                   issue_pack                  [`N-1:0],//to issue stage
    output logic [$clog2(`RS_SZ + 1)-1:0]   empty_entries_num
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
        logic [6:0]         opcode;
        PRF_IDX             T;
        PRF_IDX             t1;
        PRF_IDX             t2;
        logic               t1_ready;
        logic               t2_ready;
        ROB_IDX             rob_index;
        
    } RS_ENTRY;

    RS_ENTRY rs_entry       [`RS_SZ-1:0];
    RS_ENTRY next_rs_entry  [`RS_SZ-1:0];

    logic [`RS_SZ-1:0]      ready_entry_mask;
    logic [`RS_SZ-1:0]      issue_mask;
    logic [`RS_SZ-1:0]      mult_issue_mask;
    logic [`RS_SZ-1:0]      empty_entry_mask, next_empty_entry_mask;//
    logic [`RS_SZ-1:0]      dispatch_mask;

    logic [`RS_SZ-1:0]      mult_mask;//, next_mult_mask;

    logic [`RS_SZ-1:0] [`N-1:0]     dispatch_bus;
    logic [`RS_SZ-1:0] [`N-1:0]     issue_bus;
    logic                   empty_dispatch, empty_issue, empty_mult_issue;

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

    typedef enum logic [2:0] {
        ISSUE_1_MULT_1_ALU,
        ISSUE_1_MULT,
        ISSUE_2_ALU,
        ISSUE_1_ALU,
        ISSUE_NOTHING
    } case_t;

    case_t issue_case;
    assign issue_case = (!empty_mult_issue && !empty_issue && (alu0_ready || alu1_ready)) ? ISSUE_1_MULT_1_ALU :
                     (!empty_mult_issue && empty_issue) ? ISSUE_1_MULT :
                     (!empty_issue && alu0_ready && alu1_ready) ? ISSUE_2_ALU :
                     (!empty_issue && (alu0_ready || alu1_ready)) ? ISSUE_1_ALU :
                     ISSUE_NOTHING;

    always_comb begin
        //default
        next_rs_entry = rs_entry;
        next_empty_entry_mask = empty_entry_mask;
        ready_entry_mask = '0;
        issue_pack = '{default:'0};

        //update ready bits based on cdb
        if(cdb[0].valid) begin
            for(int j = 0; j < `RS_SZ; j++) begin
                if(rs_entry[j].busy) begin
                    if(rs_entry[j].t1 == cdb[0].complete_tag) begin
                        next_rs_entry[j].t1_ready = 1;
                    end
                    if(rs_entry[j].t2 == cdb[0].complete_tag) begin
                        next_rs_entry[j].t2_ready = 1;
                    end
                end
            end
        end

        if(cdb[1].valid) begin
            for(int j = 0; j < `RS_SZ; j++) begin
                if(rs_entry[j].busy) begin
                    if(rs_entry[j].t1 == cdb[1].complete_tag) begin
                        next_rs_entry[j].t1_ready = 1;
                    end
                    if(rs_entry[j].t2 == cdb[1].complete_tag) begin
                        next_rs_entry[j].t2_ready = 1;
                    end
                end
            end
        end

        //enqueue logic
        if(!empty_dispatch)begin
            for (int i=0; i<`RS_SZ; i++) begin
                if(dispatch_bus[0][i]) begin
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
                    next_rs_entry[i].opcode= dispatch_pack[0].opcode;
                    next_rs_entry[i].T= dispatch_pack[0].T;
                    next_rs_entry[i].t1= dispatch_pack[0].t1;
                    next_rs_entry[i].t2= dispatch_pack[0].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[0].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[0].t2_ready;
                    next_rs_entry[i].busy = 1;
                    //mark as not empty
                    next_empty_entry_mask[i] = 0;
                    //from rob
                    next_rs_entry[i].rob_index = rob_index[0];
                    //update ready bit based on cdb
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end

                end
                if(dispatch_bus[1][i] && dispatch_num == 2'd2) begin
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
                    next_rs_entry[i].opcode= dispatch_pack[1].opcode;
                    next_rs_entry[i].T= dispatch_pack[1].T;
                    next_rs_entry[i].t1= dispatch_pack[1].t1;
                    next_rs_entry[i].t2= dispatch_pack[1].t2;
                    next_rs_entry[i].t1_ready = dispatch_pack[1].t1_ready;
                    next_rs_entry[i].t2_ready = dispatch_pack[1].t2_ready;
                    next_rs_entry[i].busy = 1;
                    //mark as not empty
                    next_empty_entry_mask[i] = 0;
                    //from rob
                    next_rs_entry[i].rob_index = rob_index[1];
                    //update ready bit based on cdb
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t1) begin
                        next_rs_entry[i].t1_ready = 1;
                    end
                    if(cdb[0].valid&&cdb[0].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end else if(cdb[1].valid&&cdb[1].complete_tag == next_rs_entry[i].t2) begin
                        next_rs_entry[i].t2_ready = 1;
                    end
                end
            end
        end

        //resolve logic
        if (resolved && !mispredicted) begin
            for (int j = 0; j < `RS_SZ; j++) begin
                if (next_rs_entry[j].busy) begin
                    next_rs_entry[j].bmask = next_rs_entry[j].bmask & ~(resolved_bmask_index);
                end
            end
        end
        
        //mispredict logic
        if(mispredicted) begin
            for (int i = 0; i < `RS_SZ; i++)begin
                if(next_rs_entry[i].busy && (mispredicted_bmask_index & next_rs_entry[i].bmask)) begin
                    next_empty_entry_mask[i] = 1;
                    next_rs_entry[i] = '0;
                end
            end
        end

        //issue and clear 
        for(int j = 0; j < `RS_SZ; j++) begin
            mult_mask[j] = rs_entry[j].busy && rs_entry[j].t1_ready && rs_entry[j].t2_ready && rs_entry[j].mult;
            ready_entry_mask[j] = rs_entry[j].busy && rs_entry[j].t1_ready && rs_entry[j].t2_ready && !rs_entry[j].mult;
        end

        // Case 1: Both mult and non-mult instructions are ready
        // Issue mult to pack[0], non-mult to pack[1]
        case(issue_case)
            ISSUE_1_MULT_1_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(mult_issue_mask[i]) begin
                        //to issue pack 0
                        issue_pack[0].inst= rs_entry[i].inst;
                        issue_pack[0].PC= rs_entry[i].PC;
                        issue_pack[0].NPC= rs_entry[i].NPC;
                        issue_pack[0].opa_select= rs_entry[i].opa_select;
                        issue_pack[0].opb_select= rs_entry[i].opb_select;
                        issue_pack[0].has_dest= rs_entry[i].has_dest;
                        issue_pack[0].alu_func= rs_entry[i].alu_func;
                        issue_pack[0].mult= rs_entry[i].mult;
                        issue_pack[0].rd_mem= rs_entry[i].rd_mem;
                        issue_pack[0].wr_mem= rs_entry[i].wr_mem;
                        issue_pack[0].cond_branch= rs_entry[i].cond_branch;
                        issue_pack[0].uncond_branch= rs_entry[i].uncond_branch;
                        issue_pack[0].csr_op= rs_entry[i].csr_op;
                        issue_pack[0].halt= rs_entry[i].halt;
                        issue_pack[0].illegal= rs_entry[i].illegal;
                        issue_pack[0].bmask_index= rs_entry[i].bmask_index;
                        issue_pack[0].bmask= rs_entry[i].bmask;
                        issue_pack[0].opcode= rs_entry[i].opcode;
                        issue_pack[0].T= rs_entry[i].T;
                        issue_pack[0].t1= rs_entry[i].t1;
                        issue_pack[0].t2= rs_entry[i].t2;
                        issue_pack[0].rob_index = rs_entry[i].rob_index;

                        //mark as not busy
                        next_rs_entry[i].busy = 0;
                        //mark as empty
                        next_empty_entry_mask[i] = 1;
                    end
                    if(issue_bus[0][i]) begin
                        //to issue pack 1
                        issue_pack[1].inst= rs_entry[i].inst;
                        issue_pack[1].PC= rs_entry[i].PC;
                        issue_pack[1].NPC= rs_entry[i].NPC;
                        issue_pack[1].opa_select= rs_entry[i].opa_select;
                        issue_pack[1].opb_select= rs_entry[i].opb_select;
                        issue_pack[1].has_dest= rs_entry[i].has_dest;
                        issue_pack[1].alu_func= rs_entry[i].alu_func;
                        issue_pack[1].mult= rs_entry[i].mult;
                        issue_pack[1].rd_mem= rs_entry[i].rd_mem;
                        issue_pack[1].wr_mem= rs_entry[i].wr_mem;
                        issue_pack[1].cond_branch= rs_entry[i].cond_branch;
                        issue_pack[1].uncond_branch= rs_entry[i].uncond_branch;
                        issue_pack[1].csr_op= rs_entry[i].csr_op;
                        issue_pack[1].halt= rs_entry[i].halt;
                        issue_pack[1].illegal= rs_entry[i].illegal;
                        issue_pack[1].bmask_index= rs_entry[i].bmask_index;
                        issue_pack[1].bmask= rs_entry[i].bmask;
                        issue_pack[1].opcode= rs_entry[i].opcode;
                        issue_pack[1].T= rs_entry[i].T;
                        issue_pack[1].t1= rs_entry[i].t1;
                        issue_pack[1].t2= rs_entry[i].t2;
                        issue_pack[1].rob_index = rs_entry[i].rob_index;
                        
                        //mark as not busy
                        next_rs_entry[i].busy = 0;
                        //mark as empty
                        next_empty_entry_mask[i] = 1;
                    end
                end
            end
            // Case 2: Only mult instruction is ready
            // Issue mult to pack[0]
            ISSUE_1_MULT: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(mult_issue_mask[i]) begin
                        //to issue pack 0
                        issue_pack[0].inst= rs_entry[i].inst;
                        issue_pack[0].PC= rs_entry[i].PC;
                        issue_pack[0].NPC= rs_entry[i].NPC;
                        issue_pack[0].opa_select= rs_entry[i].opa_select;
                        issue_pack[0].opb_select= rs_entry[i].opb_select;
                        issue_pack[0].has_dest= rs_entry[i].has_dest;
                        issue_pack[0].alu_func= rs_entry[i].alu_func;
                        issue_pack[0].mult= rs_entry[i].mult;
                        issue_pack[0].rd_mem= rs_entry[i].rd_mem;
                        issue_pack[0].wr_mem= rs_entry[i].wr_mem;
                        issue_pack[0].cond_branch= rs_entry[i].cond_branch;
                        issue_pack[0].uncond_branch= rs_entry[i].uncond_branch;
                        issue_pack[0].csr_op= rs_entry[i].csr_op;
                        issue_pack[0].halt= rs_entry[i].halt;
                        issue_pack[0].illegal= rs_entry[i].illegal;
                        issue_pack[0].bmask_index= rs_entry[i].bmask_index;
                        issue_pack[0].bmask= rs_entry[i].bmask;
                        issue_pack[0].opcode= rs_entry[i].opcode;
                        issue_pack[0].T= rs_entry[i].T;
                        issue_pack[0].t1= rs_entry[i].t1;
                        issue_pack[0].t2= rs_entry[i].t2;
                        issue_pack[0].rob_index = rs_entry[i].rob_index;

                        //mark as not busy
                        next_rs_entry[i].busy = 0;
                        //mark as empty
                        next_empty_entry_mask[i] = 1;
                    end
                end
            end
            // Case 3: Only non-mult instructions are ready (no mult or mult not ready)
            // Issue 2 non-mult instructions
            ISSUE_2_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(issue_bus[0][i]) begin
                        //to issue pack 0
                        issue_pack[0].inst= rs_entry[i].inst;
                        issue_pack[0].PC= rs_entry[i].PC;
                        issue_pack[0].NPC= rs_entry[i].NPC;
                        issue_pack[0].opa_select= rs_entry[i].opa_select;
                        issue_pack[0].opb_select= rs_entry[i].opb_select;
                        issue_pack[0].has_dest= rs_entry[i].has_dest;
                        issue_pack[0].alu_func= rs_entry[i].alu_func;
                        issue_pack[0].mult= rs_entry[i].mult;
                        issue_pack[0].rd_mem= rs_entry[i].rd_mem;
                        issue_pack[0].wr_mem= rs_entry[i].wr_mem;
                        issue_pack[0].cond_branch= rs_entry[i].cond_branch;
                        issue_pack[0].uncond_branch= rs_entry[i].uncond_branch;
                        issue_pack[0].csr_op= rs_entry[i].csr_op;
                        issue_pack[0].halt= rs_entry[i].halt;
                        issue_pack[0].illegal= rs_entry[i].illegal;
                        issue_pack[0].bmask_index= rs_entry[i].bmask_index;
                        issue_pack[0].bmask= rs_entry[i].bmask;
                        issue_pack[0].opcode= rs_entry[i].opcode;
                        issue_pack[0].T= rs_entry[i].T;
                        issue_pack[0].t1= rs_entry[i].t1;
                        issue_pack[0].t2= rs_entry[i].t2;
                        issue_pack[0].rob_index = rs_entry[i].rob_index;
                        
                        //mark as not busy
                        next_rs_entry[i].busy = 0;
                        //mark as empty
                        next_empty_entry_mask[i] = 1;
                    end
                    if(issue_bus[1][i]) begin
                        //to issue pack 1
                        issue_pack[1].inst= rs_entry[i].inst;
                        issue_pack[1].PC= rs_entry[i].PC;
                        issue_pack[1].NPC= rs_entry[i].NPC;
                        issue_pack[1].opa_select= rs_entry[i].opa_select;
                        issue_pack[1].opb_select= rs_entry[i].opb_select;
                        issue_pack[1].has_dest= rs_entry[i].has_dest;
                        issue_pack[1].alu_func= rs_entry[i].alu_func;
                        issue_pack[1].mult= rs_entry[i].mult;
                        issue_pack[1].rd_mem= rs_entry[i].rd_mem;
                        issue_pack[1].wr_mem= rs_entry[i].wr_mem;
                        issue_pack[1].cond_branch= rs_entry[i].cond_branch;
                        issue_pack[1].uncond_branch= rs_entry[i].uncond_branch;
                        issue_pack[1].csr_op= rs_entry[i].csr_op;
                        issue_pack[1].halt= rs_entry[i].halt;
                        issue_pack[1].illegal= rs_entry[i].illegal;
                        issue_pack[1].bmask_index= rs_entry[i].bmask_index;
                        issue_pack[1].bmask= rs_entry[i].bmask;
                        issue_pack[1].opcode= rs_entry[i].opcode;
                        issue_pack[1].T= rs_entry[i].T;
                        issue_pack[1].t1= rs_entry[i].t1;
                        issue_pack[1].t2= rs_entry[i].t2;
                        issue_pack[1].rob_index = rs_entry[i].rob_index;
                    
                        //mark as not busy
                        next_rs_entry[i].busy = 0;
                        //mark as empty
                        next_empty_entry_mask[i] = 1;
                    end
                end
            end
            //case4: only 1 non-mult instruction is ready
            ISSUE_1_ALU: begin
                for (int i = 0; i<`RS_SZ; i++)begin
                    if(issue_bus[0][i]) begin
                        //to issue pack 0
                        issue_pack[0].inst= rs_entry[i].inst;
                        issue_pack[0].PC= rs_entry[i].PC;
                        issue_pack[0].NPC= rs_entry[i].NPC;
                        issue_pack[0].opa_select= rs_entry[i].opa_select;
                        issue_pack[0].opb_select= rs_entry[i].opb_select;
                        issue_pack[0].has_dest= rs_entry[i].has_dest;
                        issue_pack[0].alu_func= rs_entry[i].alu_func;
                        issue_pack[0].mult= rs_entry[i].mult;
                        issue_pack[0].rd_mem= rs_entry[i].rd_mem;
                        issue_pack[0].wr_mem= rs_entry[i].wr_mem;
                        issue_pack[0].cond_branch= rs_entry[i].cond_branch;
                        issue_pack[0].uncond_branch= rs_entry[i].uncond_branch;
                        issue_pack[0].csr_op= rs_entry[i].csr_op;
                        issue_pack[0].halt= rs_entry[i].halt;
                        issue_pack[0].illegal= rs_entry[i].illegal;
                        issue_pack[0].bmask_index= rs_entry[i].bmask_index;
                        issue_pack[0].bmask= rs_entry[i].bmask;
                        issue_pack[0].opcode= rs_entry[i].opcode;
                        issue_pack[0].T= rs_entry[i].T;
                        issue_pack[0].t1= rs_entry[i].t1;
                        issue_pack[0].t2= rs_entry[i].t2;
                        issue_pack[0].rob_index = rs_entry[i].rob_index;

                        //mark as not busy
                        next_rs_entry[i].busy = 0;
                        //mark as empty
                        next_empty_entry_mask[i] = 1;
                    end
                end
            end
            //case5: no instruction is ready
            ISSUE_NOTHING: begin
                //do nothing
            end
        endcase
        empty_entries_num = 0;
        for(int j = 0; j < `RS_SZ; j++) begin 
            if(next_empty_entry_mask[j]) begin 
                empty_entries_num = empty_entries_num + 1;
            end
        end
    end
    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////       sequential logic  ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    always_ff@(posedge clock)begin
        if(reset)begin
            rs_entry <= '{default: '0};
            empty_entry_mask <= '1; //all entries are empty at the beginning
        end
        else begin
            rs_entry <= next_rs_entry;
            empty_entry_mask <= next_empty_entry_mask;
        end
    end

endmodule