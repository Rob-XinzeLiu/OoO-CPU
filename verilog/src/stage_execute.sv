`include "sys_defs.svh"
`include "ISA.svh"
module stage_execute(
    input logic                             clock                               , 
    input logic                             reset                               ,
    // from RS                             
    input S_X_PACKET                        s_x_pack                      [`N:0],
    //from cdb arbiter, decide whick inst can go to cdb
    input  logic                            mult_ready                          ,
    input  logic          [1:0]             alu_ready                           ,
    
    //to complete stage
    output X_C_PACKET                       x_c_pack                    [`N-1:0],
    //to rob 
    output COND_BRANCH_PACKET               conditional_branch_out              , 
    //to fetch stage
    output MISPREDICT_PACKET                mispredict_pack_out                 ,             
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
    DATA rs1_mult,rs2_mult, rs1_cond, rs2_cond;
    MULT_FUNC func_mult;
    ALU_FUNC func1_alu,func2_alu;
    logic take;
    DATA opa1_alu,opb1_alu,opa2_alu,opb2_alu,result1_alu,result2_alu;
    logic [2:0] func_cond;
    X_C_PACKET mult_out;

 

    //broadcast combinations
    typedef enum logic [2:0] {
        BROADCAST_1_MULT,
        BROADCAST_2_ALU,
        BROADCAST_1_MULT_1_ALU,
        BROADCAST_1_ALU,
        NONE
    }execute_output_t;

    execute_output_t execute_output_type;
   
    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    ////////////////////// mispredict and resolve  ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
    logic     mis_direction;
    logic     mis_target  [1:0]  ;
    always_comb begin
        //uncond branch
        mis_target[0] = s_x_pack[0].valid && s_x_pack[0].uncond_branch  && (s_x_pack[0].predict_addr != result1_alu);
        mis_target[1] = s_x_pack[1].valid && s_x_pack[1].uncond_branch  && (s_x_pack[1].predict_addr != result2_alu);
        //conditional branch
        mis_direction = s_x_pack[2].valid && (s_x_pack[2].predict_taken != take);
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

        if(s_x_pack[2].valid && !mis_direction) begin
            resolved_bmask_index |= s_x_pack[2].bmask_index;
        end else if(s_x_pack[2].valid && mis_direction) begin
            mispredicted_mask &= s_x_pack[2].bmask;
        end

        for(int i = 0; i < 2; i++) begin
            if(s_x_pack[i].valid && s_x_pack[i].uncond_branch && !mis_target[i]) begin
                resolved_bmask_index |= s_x_pack[i].bmask_index;
            end else if(s_x_pack[i].valid && s_x_pack[i].uncond_branch && mis_target[i]) begin
                mispredicted_mask &= s_x_pack[i].bmask;
            end 
        end

        if (s_x_pack[2].valid && mis_direction && (s_x_pack[2].bmask == mispredicted_mask)) begin
            mispredicted = 1'b1;
            mispredicted_bmask_index = s_x_pack[2].bmask_index;
            //mispredict pack for fetch stage
            mispredict_pack.valid = 1'b1;
            mispredict_pack.is_cond_branch = 1'b1;
            mispredict_pack.take_branch = take;
            mispredict_pack.correct_next_pc = take ? (s_x_pack[2].PC + `RV32_signext_Bimm(s_x_pack[2].inst)) : s_x_pack[2].NPC;
        end else begin
            for (int i = 0; i < 2; i++) begin
                if (s_x_pack[i].valid && s_x_pack[i].uncond_branch && mis_target[i] && (s_x_pack[i].bmask == mispredicted_mask)) begin
                    mispredicted = 1'b1;
                    mispredicted_bmask_index = s_x_pack[i].bmask_index;
                    //mispredict pack for fetch stage
                    mispredict_pack.valid = 1'b1;
                    mispredict_pack.is_uncond_branch = 1'b1;
                    mispredict_pack.correct_next_pc = (i==0) ? result1_alu : result2_alu;
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



    //input to execute, output to complete
    B_MASK effective_bmask_mult, effective_bmask_alu0, effective_bmask_alu1;
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
        func_cond = '0;
        x_c_pack = '{default:'0};
        early_tag_bus = '{default:'0};

        ///////////////////////////////////////////////////////////////////////
        //////////////////////                         ////////////////////////
        //////////////////////input to function units  ////////////////////////
        //////////////////////                         ////////////////////////
        ///////////////////////////////////////////////////////////////////////
        //third pack decide conditional branch
        if (s_x_pack[2].valid ) begin
            rs1_cond = s_x_pack[2].rs1_value;
            rs2_cond = s_x_pack[2].rs2_value;
            func_cond = s_x_pack[2].inst.b.funct3;
        end

        //first pack decide mult or alu
        if (s_x_pack[0].valid && s_x_pack[0].mult ) begin
            rs1_mult = s_x_pack[0].rs1_value;
            rs2_mult = s_x_pack[0].rs2_value;
            func_mult = s_x_pack[0].inst.r.funct3;
            start_mult = '1;

        end else if (s_x_pack[0].valid ) begin
            func1_alu = s_x_pack[0].alu_func;
            case(s_x_pack[0].opa_select) 
                OPA_IS_RS1:  opa1_alu = s_x_pack[0].rs1_value;
                OPA_IS_NPC:  opa1_alu = s_x_pack[0].NPC;    //npc
                OPA_IS_PC:   opa1_alu = s_x_pack[0].PC;    //pc
                OPA_IS_ZERO: opa1_alu = 0;
                default:     opa1_alu = 32'hdeadface; // dead face
            endcase
            case(s_x_pack[0].opb_select) 
                OPB_IS_RS2:   opb1_alu = s_x_pack[0].rs2_value;
                OPB_IS_I_IMM: opb1_alu = `RV32_signext_Iimm(s_x_pack[0].inst);
                OPB_IS_S_IMM: opb1_alu = `RV32_signext_Simm(s_x_pack[0].inst);
                OPB_IS_B_IMM: opb1_alu = `RV32_signext_Bimm(s_x_pack[0].inst);
                OPB_IS_U_IMM: opb1_alu = `RV32_signext_Uimm(s_x_pack[0].inst);
                OPB_IS_J_IMM: opb1_alu = `RV32_signext_Jimm(s_x_pack[0].inst);
                default:      opb1_alu = 32'hfacefeed; // face feed
            endcase
        end

        // second pack decide alu
        if (s_x_pack[1].valid ) begin
            if( s_x_pack[0].mult) begin
                func1_alu = s_x_pack[1].alu_func;
                case(s_x_pack[1].opa_select) 
                    OPA_IS_RS1:  opa1_alu = s_x_pack[1].rs1_value;
                    OPA_IS_NPC:  opa1_alu = s_x_pack[1].NPC;    //npc
                    OPA_IS_PC:   opa1_alu = s_x_pack[1].PC;    //pc
                    OPA_IS_ZERO: opa1_alu = 0;
                    default:     opa1_alu = 32'hdeadface; // dead face
                endcase
                case(s_x_pack[1].opb_select) 
                    OPB_IS_RS2:   opb1_alu = s_x_pack[1].rs2_value;
                    OPB_IS_I_IMM: opb1_alu = `RV32_signext_Iimm(s_x_pack[1].inst);
                    OPB_IS_S_IMM: opb1_alu = `RV32_signext_Simm(s_x_pack[1].inst);
                    OPB_IS_B_IMM: opb1_alu = `RV32_signext_Bimm(s_x_pack[1].inst);
                    OPB_IS_U_IMM: opb1_alu = `RV32_signext_Uimm(s_x_pack[1].inst);
                    OPB_IS_J_IMM: opb1_alu = `RV32_signext_Jimm(s_x_pack[1].inst);
                    default:      opb1_alu = 32'hfacefeed; // face feed
                endcase
            end else if (s_x_pack[0].valid) begin
                func2_alu = s_x_pack[1].alu_func;
                case(s_x_pack[1].opa_select) 
                    OPA_IS_RS1:  opa2_alu = s_x_pack[1].rs1_value;
                    OPA_IS_NPC:  opa2_alu = s_x_pack[1].NPC;    //npc
                    OPA_IS_PC:   opa2_alu = s_x_pack[1].PC;    //pc
                    OPA_IS_ZERO: opa2_alu = 0;
                    default:     opa2_alu = 32'hdeadface; // dead face
                endcase
                case(s_x_pack[1].opb_select) 
                    OPB_IS_RS2:   opb2_alu = s_x_pack[1].rs2_value;
                    OPB_IS_I_IMM: opb2_alu = `RV32_signext_Iimm(s_x_pack[1].inst);
                    OPB_IS_S_IMM: opb2_alu = `RV32_signext_Simm(s_x_pack[1].inst);
                    OPB_IS_B_IMM: opb2_alu = `RV32_signext_Bimm(s_x_pack[1].inst);
                    OPB_IS_U_IMM: opb2_alu = `RV32_signext_Uimm(s_x_pack[1].inst);
                    OPB_IS_J_IMM: opb2_alu = `RV32_signext_Jimm(s_x_pack[1].inst);
                    default:      opb2_alu = 32'hfacefeed; // face feed
                endcase
            end else begin
                func1_alu = s_x_pack[1].alu_func;
                case(s_x_pack[1].opa_select) 
                    OPA_IS_RS1:  opa1_alu = s_x_pack[1].rs1_value;
                    OPA_IS_NPC:  opa1_alu = s_x_pack[1].NPC;    //npc
                    OPA_IS_PC:   opa1_alu = s_x_pack[1].PC;    //pc
                    OPA_IS_ZERO: opa1_alu = 0;
                    default:     opa1_alu = 32'hdeadface; // dead face
                endcase
                case(s_x_pack[1].opb_select) 
                    OPB_IS_RS2:   opb1_alu = s_x_pack[1].rs2_value;
                    OPB_IS_I_IMM: opb1_alu = `RV32_signext_Iimm(s_x_pack[1].inst);
                    OPB_IS_S_IMM: opb1_alu = `RV32_signext_Simm(s_x_pack[1].inst);
                    OPB_IS_B_IMM: opb1_alu = `RV32_signext_Bimm(s_x_pack[1].inst);
                    OPB_IS_U_IMM: opb1_alu = `RV32_signext_Uimm(s_x_pack[1].inst);
                    OPB_IS_J_IMM: opb1_alu = `RV32_signext_Jimm(s_x_pack[1].inst);
                    default:      opb1_alu = 32'hfacefeed; // face feed
                endcase
            end
        end

        ///////////////////////////////////////////////////////////////////////
        //////////////////////                         ////////////////////////
        //////////////////////   cdb broadcast logic   ////////////////////////
        //////////////////////                         ////////////////////////
        ///////////////////////////////////////////////////////////////////////
        
        //bmask after resolve
        effective_bmask_mult = resolved ? (mult_out.bmask     & ~resolved_bmask_index) : mult_out.bmask;
        effective_bmask_alu0 = resolved ? (s_x_pack[0].bmask  & ~resolved_bmask_index) : s_x_pack[0].bmask;
        effective_bmask_alu1 = resolved ? (s_x_pack[1].bmask  & ~resolved_bmask_index) : s_x_pack[1].bmask;  

        //define cdb broadcast cases 
        execute_output_type = NONE;
        if(mult_ready) begin
            if(alu_ready[0]) begin
                execute_output_type = BROADCAST_1_MULT_1_ALU;
            end else begin
                execute_output_type = BROADCAST_1_MULT;
            end
        end
        
        if (!mult_ready) begin
            if(alu_ready[0] && alu_ready[1]) begin
                execute_output_type = BROADCAST_2_ALU;
            end else if (alu_ready[0] && !alu_ready[1]) begin
                execute_output_type = BROADCAST_1_ALU;
            end
        end

        //broadcast control logic(without considering mispredict and resolve)
        case(execute_output_type)
            BROADCAST_1_MULT: begin
                x_c_pack[0].valid          = mult_done && !(mispredicted && |(effective_bmask_mult & mispredicted_bmask_index));
                x_c_pack[0].complete_index = mult_out.complete_index;
                x_c_pack[0].complete_tag   = mult_out.complete_tag;
                x_c_pack[0].bmask          = effective_bmask_mult;
                x_c_pack[0].result         = mult_out.result;
                x_c_pack[0].has_dest       = 1'b1;
                x_c_pack[1].valid          = 1'b0;
                //etb
                early_tag_bus[0].valid = 'b1;
                early_tag_bus[0].tag = mult_out.complete_tag;
            end
            BROADCAST_2_ALU: begin
                x_c_pack[0].valid          = (s_x_pack[0].valid && (s_x_pack[0].bmask_index == mispredicted_bmask_index))? 1'b1: 
                                             (s_x_pack[0].valid && !(mispredicted && |(effective_bmask_alu0 & mispredicted_bmask_index)));
                x_c_pack[0].complete_index = s_x_pack[0].rob_index;
                x_c_pack[0].complete_tag   = s_x_pack[0].tag;
                x_c_pack[0].bmask          = effective_bmask_alu0;
                x_c_pack[0].result         = result1_alu;
                x_c_pack[0].has_dest       = s_x_pack[0].has_dest;
                x_c_pack[0].uncond_branch  = s_x_pack[0].uncond_branch;
                x_c_pack[1].valid          = (s_x_pack[1].valid && (s_x_pack[1].bmask_index == mispredicted_bmask_index))? 1'b1: 
                                             (s_x_pack[1].valid && !(mispredicted && |(effective_bmask_alu1 & mispredicted_bmask_index)));
                x_c_pack[1].complete_index = s_x_pack[1].rob_index;
                x_c_pack[1].complete_tag   = s_x_pack[1].tag;
                x_c_pack[1].bmask          = effective_bmask_alu1;
                x_c_pack[1].result         = result2_alu;
                x_c_pack[1].has_dest       = s_x_pack[1].has_dest;
                x_c_pack[1].uncond_branch  = s_x_pack[1].uncond_branch;
                //etb
                early_tag_bus[0].valid = s_x_pack[0].has_dest;
                early_tag_bus[0].tag = s_x_pack[0].tag;
                early_tag_bus[1].valid = s_x_pack[1].has_dest;
                early_tag_bus[1].tag = s_x_pack[1].tag;
            end
            BROADCAST_1_MULT_1_ALU: begin
                x_c_pack[0].valid          = mult_done && !(mispredicted && |(effective_bmask_mult & mispredicted_bmask_index));
                x_c_pack[0].complete_index = mult_out.complete_index;
                x_c_pack[0].complete_tag   = mult_out.complete_tag;
                x_c_pack[0].bmask          = effective_bmask_mult;
                x_c_pack[0].result         = mult_out.result;
                x_c_pack[0].has_dest       = 'b1;
                x_c_pack[1].valid          = (s_x_pack[1].valid && (s_x_pack[1].bmask_index == mispredicted_bmask_index))? 1'b1: 
                                             (s_x_pack[1].valid && !(mispredicted && |(effective_bmask_alu1 & mispredicted_bmask_index)));
                x_c_pack[1].complete_index = s_x_pack[1].rob_index;
                x_c_pack[1].complete_tag   = s_x_pack[1].tag;
                x_c_pack[1].bmask          = effective_bmask_alu1;
                x_c_pack[1].result         = result1_alu;
                x_c_pack[1].has_dest       = s_x_pack[1].has_dest;
                x_c_pack[1].uncond_branch  = s_x_pack[1].uncond_branch;
                //etb
                early_tag_bus[0].valid = 1;
                early_tag_bus[0].tag = mult_out.complete_tag;
                early_tag_bus[1].valid = s_x_pack[1].has_dest;
                early_tag_bus[1].tag = s_x_pack[1].tag;
            end
            BROADCAST_1_ALU: begin
                x_c_pack[0].valid          = (s_x_pack[0].valid && (s_x_pack[0].bmask_index == mispredicted_bmask_index))? 1'b1: 
                                             (s_x_pack[0].valid && !(mispredicted && |(effective_bmask_alu0 & mispredicted_bmask_index)));
                x_c_pack[0].complete_index = s_x_pack[0].rob_index;
                x_c_pack[0].complete_tag   = s_x_pack[0].tag;
                x_c_pack[0].bmask          = effective_bmask_alu0;
                x_c_pack[0].result         = result1_alu;
                x_c_pack[0].has_dest       = s_x_pack[0].has_dest;
                x_c_pack[0].uncond_branch  = s_x_pack[0].uncond_branch;
                x_c_pack[1].valid          = 1'b0;
                //etb
                early_tag_bus[0].valid = s_x_pack[0].has_dest;
                early_tag_bus[0].tag = s_x_pack[0].tag;
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
        conditional_branch_out = '{default:'0};
        if (s_x_pack[2].valid && !|(s_x_pack[2].bmask & mispredicted_bmask_index) ||
            (s_x_pack[2].bmask_index == mispredicted_bmask_index ) || !mispredicted) begin
            conditional_branch_out.valid = 1'b1;
            //conditional_branch_out.take_branch = take;
            conditional_branch_out.br_rob_idx = s_x_pack[2].rob_index;
           // conditional_branch_out.correct_next_pc = take ? branch_target : s_x_pack[2].NPC;
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

        .dest_tag_in(s_x_pack[0].tag),
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


