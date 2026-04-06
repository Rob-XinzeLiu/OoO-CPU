`include "sys_defs.svh"
`include "ISA.svh"
module stage_execute(
    input logic                             clock                               , 
    input logic                             reset                               ,
    // from RS                             
    input S_X_PACKET                        s_x_pack                      [5:0],
    //from cdb, data forwarding
    input X_C_PACKET                [`N-1:0]        cdb                         ,
    //from lq
    input LQ_PACKET                         lq_in                               ,   
    //to complete stage
    output X_C_PACKET                       x_c_pack                    [`N-1:0],
    //to rob 
    output COND_BRANCH_PACKET               conditional_branch_out              , 
    //to fetch stage
    output MISPREDICT_PACKET                mispredict_pack_out                 , 
    //to lq
    output LQ_PACKET                        lq_execute_pack                     ,  
    //to sq and rob
    output SQ_PACKET                        sq_execute_pack                     ,
    //to cdb arbiter 
    output logic                            cdb_req_mult                        ,
    //mispredict and resolve logic to other stages and registers                            
    output logic                            mispredict_signal_out               ,
    output B_MASK                           mispredict_index_out                ,
    output B_MASK                           mispredict_bmask_out                ,
    output logic                            resolve_signal_out                  ,
    output B_MASK                           resolve_index_out                   ,
    output ETB_TAG_PACKET                   early_tag_bus               [`N-1:0]
);

    //wires for function units
    logic start_mult, mult_done;
    DATA rs1_mult,rs2_mult, rs1_cond, rs2_cond, rs1_load, rs1_store, rs2_store;
    MULT_FUNC func_mult;
    ALU_FUNC func1_alu,func2_alu;
    logic take;
    DATA opa1_alu,opb1_alu,opa2_alu,opb2_alu,result1_alu,result2_alu;
    logic [2:0] func_cond;
    X_C_PACKET mult_out;

 

    //broadcast combinations
    typedef enum logic [3:0] {
        BROADCAST_1_MULT,
        BROADCAST_1_MULT_1_LOAD,
        BROADCAST_1_LOAD_1_ALU,
        BROADCAST_1_LOAD,
        BROADCAST_2_ALU,
        BROADCAST_1_MULT_1_ALU,
        BROADCAST_ALU_1,
        BROADCAST_ALU_2,
        NONE
    }execute_output_t;

    execute_output_t execute_output_type;
   
    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    ////////////////////// mispredict and resolve  ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    logic     mis_direction;
    logic     mis_target  [1:0];
    ADDR actual_cond_target;
    assign actual_cond_target = s_x_pack[4].PC + `RV32_signext_Bimm(s_x_pack[4].inst);
    
    always_comb begin
        //uncond branch
        mis_target[0] = s_x_pack[2].valid && s_x_pack[2].jalr  && (s_x_pack[2].predict_addr != result1_alu);
        mis_target[1] = s_x_pack[3].valid && s_x_pack[3].jalr  && (s_x_pack[3].predict_addr != result2_alu);
        //conditional branch
        mis_direction = s_x_pack[4].valid && (s_x_pack[4].predict_taken != take);
    end
    
    logic mispredicted;
    B_MASK mispredicted_bmask_index;
    logic resolved;
    B_MASK resolved_bmask_index;
    B_MASK mispredicted_mask;
    MISPREDICT_PACKET mispredict_pack;
    assign mispredict_pack_out = mispredict_pack;


    always_comb begin
        mispredicted = '0;
        resolved = '0;
        mispredicted_bmask_index = '0;
        resolved_bmask_index = '0;
        mispredicted_mask = '1;
        mispredict_pack = '{default:'0};

        // set up mispredicted_mask：AND all the bmask of mispredict branch
        if (s_x_pack[4].valid && mis_direction ) begin
            mispredicted_mask &= s_x_pack[4].bmask;//cond branch
        end
        for (int i = 2; i < 4; i++) begin
            if (s_x_pack[i].valid && s_x_pack[i].jalr && mis_target[i-2]) begin
                mispredicted_mask &= s_x_pack[i].bmask;//uncond branch
            end
        end

        // resolve
        if (s_x_pack[4].valid && !mis_direction ) begin
            resolved_bmask_index |= s_x_pack[4].bmask_index;
        end
        for (int i = 2; i < 4; i++) begin
            if (s_x_pack[i].valid && s_x_pack[i].jalr && !mis_target[i-2]) begin
                resolved_bmask_index |= s_x_pack[i].bmask_index;
            end
        end

        // find the oldest mispredict
        if (s_x_pack[4].valid && s_x_pack[4].cond_branch && 
            mis_direction  && (s_x_pack[4].bmask == mispredicted_mask)) begin
            mispredicted             = 1'b1;
            mispredicted_bmask_index = s_x_pack[4].bmask_index;
            mispredict_pack.valid          = 1'b1;

            mispredict_pack.take_branch    = take;
            mispredict_pack.correct_next_pc = take ? actual_cond_target : s_x_pack[4].NPC;
            mispredict_pack.c_type          = s_x_pack[4].c_type;
            mispredict_pack.current_PC      = s_x_pack[4].PC;
            mispredict_pack.current_head    = s_x_pack[4].current_head;
            mispredict_pack.current_count   = s_x_pack[4].current_count;
        end else begin
            for (int i = 2; i < 4; i++) begin
                if (s_x_pack[i].valid && s_x_pack[i].jalr && 
                    mis_target[i-2] && 
                    (s_x_pack[i].bmask == mispredicted_mask)) begin
                    mispredicted             = 1'b1;
                    mispredicted_bmask_index = s_x_pack[i].bmask_index;
                    mispredict_pack.valid            = 1'b1;
                    mispredict_pack.take_branch      = 1'b1;
                    mispredict_pack.correct_next_pc  = (i==2) ? result1_alu : result2_alu;
                    mispredict_pack.c_type          = s_x_pack[i].c_type;
                    mispredict_pack.current_PC      = s_x_pack[i].PC;
                    mispredict_pack.current_head    = s_x_pack[i].current_head;
                    mispredict_pack.current_count   = s_x_pack[i].current_count;
                end
            end

        end

        resolved = (resolved_bmask_index != 'd0);
    end
    assign resolve_signal_out = resolved;
    assign mispredict_signal_out = mispredicted;
    assign mispredict_index_out = mispredicted_bmask_index;
    assign resolve_index_out = resolved_bmask_index;
    assign mispredict_bmask_out = mispredicted_mask;




    DATA [5:0] fwd_data_1, fwd_data_2;
    logic [5:0] fwd_hit_1, fwd_hit_2;


    always_comb begin
        //default
        start_mult = '0;
        rs1_mult = '0;
        rs2_mult = '0;
        func_mult = '0;
        opa1_alu ='0;
        opa2_alu ='0;
        opb1_alu = '0;
        opb2_alu = '0;
        func1_alu ='0;
        func2_alu ='0;
        rs1_cond ='0;
        rs2_cond = '0;
        rs1_load = '0;
        rs1_store = '0;
        rs2_store = '0;
        func_cond = '0;
        fwd_data_1 = '0;
        fwd_data_2 = '0;
        fwd_hit_1 = '0;
        fwd_hit_2 = '0;
        lq_execute_pack = '0;
        sq_execute_pack = '0;
        x_c_pack = '{default:'0};
        early_tag_bus = '{default:'0};


        //data forwarding from cdb
        for(int i = 0; i < 6; i++)begin
            for(int j = 0; j < `N; j++)begin
                if((cdb[j].complete_tag == s_x_pack[i].t1) && s_x_pack[i].t1 != 0) begin
                    fwd_data_1[i] = cdb[j].result;
                    fwd_hit_1[i] = 1;
                end
                if(cdb[j].complete_tag == s_x_pack[i].t2 && s_x_pack[i].t2 != 0) begin
                    fwd_data_2[i] = cdb[j].result;
                    fwd_hit_2[i] = 1;
                end
            end
        end

        ///////////////////////////////////////////////////////////////////////
        //////////////////////                         ////////////////////////
        //////////////////////input to function units  ////////////////////////
        //////////////////////                         ////////////////////////
        ///////////////////////////////////////////////////////////////////////
        //first pack decide mult 
        if (s_x_pack[0].valid) begin
            rs1_mult = fwd_hit_1[0]? fwd_data_1[0] : s_x_pack[0].rs1_value;
            rs2_mult = fwd_hit_2[0]? fwd_data_2[0] : s_x_pack[0].rs2_value;
            func_mult = s_x_pack[0].inst.r.funct3;
            start_mult = '1;
        end   

        //second pack decide load
        if (s_x_pack[1].valid) begin
            rs1_load = fwd_hit_1[1]? fwd_data_1[1] : s_x_pack[1].rs1_value;
        end

        //third pack decide alu1
        if (s_x_pack[2].valid) begin
            func1_alu = s_x_pack[2].alu_func;
            case(s_x_pack[2].opa_select) 
                OPA_IS_RS1:  opa1_alu = fwd_hit_1[2]? fwd_data_1[2] : s_x_pack[2].rs1_value;
                OPA_IS_NPC:  opa1_alu = s_x_pack[2].NPC;    //npc
                OPA_IS_PC:   opa1_alu = s_x_pack[2].PC;    //pc
                OPA_IS_ZERO: opa1_alu = 0;
                default:     opa1_alu = 32'hdeadface; // dead face
            endcase
            case(s_x_pack[2].opb_select) 
                OPB_IS_RS2:   opb1_alu = fwd_hit_2[2]? fwd_data_2[2] : s_x_pack[2].rs2_value;
                OPB_IS_I_IMM: opb1_alu = `RV32_signext_Iimm(s_x_pack[2].inst);
                OPB_IS_S_IMM: opb1_alu = `RV32_signext_Simm(s_x_pack[2].inst);
                OPB_IS_B_IMM: opb1_alu = `RV32_signext_Bimm(s_x_pack[2].inst);
                OPB_IS_U_IMM: opb1_alu = `RV32_signext_Uimm(s_x_pack[2].inst);
                OPB_IS_J_IMM: opb1_alu = `RV32_signext_Jimm(s_x_pack[2].inst);
                default:      opb1_alu = 32'hfacefeed; // face feed
            endcase
        end

        //fourth pack decide alu2
        if (s_x_pack[3].valid) begin
            func2_alu = s_x_pack[3].alu_func;
            case(s_x_pack[3].opa_select) 
                OPA_IS_RS1:  opa2_alu = fwd_hit_1[3]? fwd_data_1[3] : s_x_pack[3].rs1_value;
                OPA_IS_NPC:  opa2_alu = s_x_pack[3].NPC;    //npc
                OPA_IS_PC:   opa2_alu = s_x_pack[3].PC;    //pc
                OPA_IS_ZERO: opa2_alu = 0;
                default:     opa2_alu = 32'hdeadface; // dead face
            endcase
            case(s_x_pack[3].opb_select) 
                OPB_IS_RS2:   opb2_alu = fwd_hit_2[3]? fwd_data_2[3] : s_x_pack[3].rs2_value;
                OPB_IS_I_IMM: opb2_alu = `RV32_signext_Iimm(s_x_pack[3].inst);
                OPB_IS_S_IMM: opb2_alu = `RV32_signext_Simm(s_x_pack[3].inst);
                OPB_IS_B_IMM: opb2_alu = `RV32_signext_Bimm(s_x_pack[3].inst);
                OPB_IS_U_IMM: opb2_alu = `RV32_signext_Uimm(s_x_pack[3].inst);
                OPB_IS_J_IMM: opb2_alu = `RV32_signext_Jimm(s_x_pack[3].inst);
                default:      opb2_alu = 32'hfacefeed; // face feed
            endcase
        end

        
        //fifth pack decide conditional branch
        if (s_x_pack[4].valid ) begin
            rs1_cond = fwd_hit_1[4]? fwd_data_1[4] : s_x_pack[4].rs1_value;
            rs2_cond = fwd_hit_2[4]? fwd_data_2[4] : s_x_pack[4].rs2_value;
            func_cond = s_x_pack[4].inst.b.funct3;
        end

        //sixth pack decide store
        if(s_x_pack[5].valid) begin
            rs1_store = fwd_hit_1[5]? fwd_data_1[5] : s_x_pack[5].rs1_value;
            rs2_store = fwd_hit_2[5]? fwd_data_2[5] : s_x_pack[5].rs2_value;
        end


        //////////////////////////////////////////////////////////////////////////
        //////////////////////                            ////////////////////////
        ////////////////////// load and store  calculate  ////////////////////////
        //////////////////////                            ////////////////////////
        //////////////////////////////////////////////////////////////////////////

        if(s_x_pack[1].valid) begin
            lq_execute_pack.valid = 1;
            lq_execute_pack.addr = rs1_load + `RV32_signext_Iimm(s_x_pack[1].inst);
            lq_execute_pack.lq_index = s_x_pack[1].lq_index;
        end

        if(s_x_pack[5].valid) begin
            sq_execute_pack.valid = 1;
            sq_execute_pack.addr = rs1_store + `RV32_signext_Simm(s_x_pack[5].inst);
            sq_execute_pack.data = rs2_store;
            sq_execute_pack.sq_index = s_x_pack[5].sq_index;
            sq_execute_pack.rob_index = s_x_pack[5].rob_index;
        end

        


        ///////////////////////////////////////////////////////////////////////
        //////////////////////                         ////////////////////////
        //////////////////////   cdb broadcast logic   ////////////////////////
        //////////////////////                         ////////////////////////
        /////////////////////////////////////////////////////////////////////// 
       
        //define cdb broadcast cases 
        execute_output_type = NONE;
        if(mult_done) begin
            if(lq_in.valid) begin
                execute_output_type = BROADCAST_1_MULT_1_LOAD;
            end else if(s_x_pack[2].valid) begin
                execute_output_type = BROADCAST_1_MULT_1_ALU;
            end else begin
                execute_output_type = BROADCAST_1_MULT;
            end
        end
        
        if (!mult_done) begin
            if(lq_in.valid) begin
                if (s_x_pack[2].valid) begin
                    execute_output_type = BROADCAST_1_LOAD_1_ALU;
                end else begin
                    execute_output_type = BROADCAST_1_LOAD;
                end
            end else if (s_x_pack[2].valid && s_x_pack[3].valid) begin
                execute_output_type = BROADCAST_2_ALU;
            end else if (s_x_pack[2].valid && ! s_x_pack[3].valid) begin
                execute_output_type = BROADCAST_ALU_1;
            end else if (!s_x_pack[2].valid &&  s_x_pack[3].valid) begin
                execute_output_type = BROADCAST_ALU_2;
            end
        end

        //broadcast control logic(without considering mispredict and resolve)
        case(execute_output_type)
            BROADCAST_1_MULT_1_LOAD: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = mult_out.complete_index;
                x_c_pack[0].complete_tag   = mult_out.complete_tag;
                x_c_pack[0].result         = mult_out.result;
                x_c_pack[1].valid          = 1;
                x_c_pack[1].complete_index = lq_in.rob_index;
                x_c_pack[1].complete_tag   = lq_in.dest_tag;
                x_c_pack[1].result         = lq_in.data;

                //etb
                early_tag_bus[0].valid = 'b1;
                early_tag_bus[0].tag = mult_out.complete_tag;
                early_tag_bus[1].valid = 'b1;
                early_tag_bus[1].tag = lq_in.dest_tag;

            end

            BROADCAST_1_LOAD_1_ALU: begin    
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = lq_in.rob_index;
                x_c_pack[0].complete_tag   = lq_in.dest_tag;
                x_c_pack[0].result         = lq_in.data;

                x_c_pack[1].valid          = 1;
                x_c_pack[1].complete_index = s_x_pack[2].rob_index;
                x_c_pack[1].complete_tag   = s_x_pack[2].T;
                x_c_pack[1].result         = (s_x_pack[2].jalr || s_x_pack[2].jal)? s_x_pack[2].NPC : result1_alu;

                //etb
                early_tag_bus[0].valid = 'b1;
                early_tag_bus[0].tag = lq_in.dest_tag;
                early_tag_bus[1].valid = 'b1;
                early_tag_bus[1].tag = s_x_pack[2].T;

            end

            BROADCAST_1_LOAD: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = lq_in.rob_index;
                x_c_pack[0].complete_tag   = lq_in.dest_tag;
                x_c_pack[0].result         = lq_in.data;

                //etb
                early_tag_bus[0].valid = 'b1;
                early_tag_bus[0].tag = lq_in.dest_tag;
            end

            BROADCAST_1_MULT: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = mult_out.complete_index;
                x_c_pack[0].complete_tag   = mult_out.complete_tag;
                x_c_pack[0].result         = mult_out.result;
                //etb
                early_tag_bus[0].valid = 'b1;
                early_tag_bus[0].tag = mult_out.complete_tag;
            end

            BROADCAST_2_ALU: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = s_x_pack[2].rob_index;
                x_c_pack[0].complete_tag   = s_x_pack[2].T;
                x_c_pack[0].result         = (s_x_pack[2].jalr || s_x_pack[2].jal)? s_x_pack[2].NPC : result1_alu;

                x_c_pack[1].valid          = 1;
                x_c_pack[1].complete_index = s_x_pack[3].rob_index;
                x_c_pack[1].complete_tag   = s_x_pack[3].T;
                x_c_pack[1].result         = (s_x_pack[3].jalr || s_x_pack[3].jal)? s_x_pack[3].NPC : result2_alu;

                //etb
                early_tag_bus[0].valid = 1;
                early_tag_bus[0].tag = s_x_pack[2].T;
                early_tag_bus[1].valid = 1;
                early_tag_bus[1].tag = s_x_pack[3].T;
            end

            BROADCAST_1_MULT_1_ALU: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = mult_out.complete_index;
                x_c_pack[0].complete_tag   = mult_out.complete_tag;
                x_c_pack[0].result         = mult_out.result;

                x_c_pack[1].valid          = 1;
                x_c_pack[1].complete_index = s_x_pack[2].rob_index;
                x_c_pack[1].complete_tag   = s_x_pack[2].T;
                x_c_pack[1].result         = (s_x_pack[2].jalr || s_x_pack[2].jal)? s_x_pack[2].NPC :result1_alu;

                //etb
                early_tag_bus[0].valid = 1;
                early_tag_bus[0].tag = mult_out.complete_tag;
                early_tag_bus[1].valid = 1;
                early_tag_bus[1].tag = s_x_pack[2].T;
            end

            BROADCAST_ALU_1: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = s_x_pack[2].rob_index;
                x_c_pack[0].complete_tag   = s_x_pack[2].T;
                x_c_pack[0].result         = (s_x_pack[2].jalr || s_x_pack[2].jal)? s_x_pack[2].NPC : result1_alu;

                //etb
                early_tag_bus[0].valid = 1;
                early_tag_bus[0].tag = s_x_pack[2].T;
            end

            BROADCAST_ALU_2: begin
                x_c_pack[0].valid          = 1;
                x_c_pack[0].complete_index = s_x_pack[3].rob_index;
                x_c_pack[0].complete_tag   = s_x_pack[3].T;
                x_c_pack[0].result         = (s_x_pack[3].jalr || s_x_pack[3].jal)? s_x_pack[3].NPC : result2_alu;

                //etb
                early_tag_bus[0].valid = 1;
                early_tag_bus[0].tag = s_x_pack[3].T;
            end
            
            NONE:begin
                x_c_pack = '{default:'0};
                early_tag_bus = '{default:'0};
            end

            default: begin
                x_c_pack = '{default:'0};
                early_tag_bus = '{default:'0};
            end
        endcase
    end

    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    ////////////////////// conditional branch  out ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    
   // DATA branch_target;
   // assign branch_target = s_x_pack[2].valid? (s_x_pack[2].PC + `RV32_signext_Bimm(s_x_pack[2].inst)) : 'b0;
    always_comb begin
        conditional_branch_out = '0;
        if(s_x_pack[4].valid) begin
            if (~|(s_x_pack[4].bmask & mispredicted_bmask_index) ||
                (s_x_pack[4].bmask_index == mispredicted_bmask_index ) || !mispredicted) begin
                conditional_branch_out.valid = 1'b1;
                conditional_branch_out.result = take;
                conditional_branch_out.br_rob_idx = s_x_pack[4].rob_index;
                conditional_branch_out.PC = s_x_pack[4].PC;
            end
        end
    end

    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    ////////////////////// mispredict out to fetch ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////

       //instantiate functional units
    mult  mult1(
        .clock(clock), 
        .reset(reset), 
        .start(start_mult),
        .rs1(rs1_mult), 
        .rs2(rs2_mult),
        .func(func_mult),

        .dest_tag_in(s_x_pack[0].T),
        .rob_idx_in(s_x_pack[0].rob_index),
        .bmask_in(s_x_pack[0].bmask),
        .mispredicted(mispredicted),
        .mispredicted_bmask_index(mispredicted_bmask_index),
        .resolved(resolved),
        .resolved_bmask_index(resolved_bmask_index),
        .bmask_out(mult_out.bmask),
        .rob_idx_out(mult_out.complete_index),
        .dest_tag_out(mult_out.complete_tag),
        .cdb_req_mult(cdb_req_mult),

        .result(mult_out.result),
        .done(mult_done)
    );

    alu alu1 (
        .opa(opa1_alu),
        .opb(opb1_alu),
        .alu_func(func1_alu),
        .result(result1_alu)
    );
    alu alu2 (
        .opa(opa2_alu),
        .opb(opb2_alu),
        .alu_func(func2_alu),
        .result(result2_alu)
    );
    conditional_branch conditional_branch(
        .rs1(rs1_cond),
        .rs2(rs2_cond),
        .func(func_cond),
        .take(take)
    );

    
endmodule

module alu (
    input DATA     opa,
    input DATA     opb,
    input ALU_FUNC alu_func,

    output DATA result
);

    always_comb begin
        case (alu_func)
            ALU_ADD:  result = opa + opb;
            ALU_SUB:  result = opa - opb;
            ALU_AND:  result = opa & opb;
            ALU_SLT:  result = signed'(opa) < signed'(opb);
            ALU_SLTU: result = opa < opb;
            ALU_OR:   result = opa | opb;
            ALU_XOR:  result = opa ^ opb;
            ALU_SRL:  result = opa >> opb[4:0];
            ALU_SLL:  result = opa << opb[4:0];
            ALU_SRA:  result = signed'(opa) >>> opb[4:0]; // arithmetic from logical shift
            // here to prevent latches:
            default:  result = 32'hfacebeec;
        endcase
    end

endmodule // alu


module conditional_branch (
    input DATA  rs1,
    input DATA  rs2,
    input [2:0] func, // Which branch condition to check

    output logic take // True/False condition result
);

    always_comb begin
        case (func)
            3'b000:  take = signed'(rs1) == signed'(rs2); // BEQ
            3'b001:  take = signed'(rs1) != signed'(rs2); // BNE
            3'b100:  take = signed'(rs1) <  signed'(rs2); // BLT
            3'b101:  take = signed'(rs1) >= signed'(rs2); // BGE
            3'b110:  take = rs1 < rs2;                    // BLTU
            3'b111:  take = rs1 >= rs2;                   // BGEU
            default: take = `FALSE;
        endcase
    end

endmodule // conditional_branch


