`include "sys_defs.svh"
module execute_stage(

    input logic                             clock                               , 
    input logic                             reset                               ,
    // from RS                            , 
    input S_X_PACKET                        s_x_pack [`N:0]                     ,
   
    //For branch resolve
    // input logic                             resolved                            ,
    // input X_C_PACKET                        resolved_bmask_index                ,
    // //For branch mispredict
    // input logic                             mispredicted                        ,
    // input B_MASK                            mispredicted_bmask_index            , 

    //to complete stage
    output X_C_PACKET                       x_c_pack [`N-1:0]                   ,

    //to cpu.sv
    output X_C_PACKET                       condition_pack                      ,

    //to RS                            
    output logic                             mispredicted                        ,
    output B_MASK                            mispredicted_bmask_index            ,
    output logic                             resolved                            ,
    output B_MASK                            resolved_bmask_index 
);

logic mispredicted;
B_MASK mispredicted_bmask_index,mispredicted_bmask_index_n;
logic resolved;
B_MASK resolved_bmask_index,resolved_bmask_index_n;



X_C_PACKET xc_pack[`N-1:0], xc_pack_n[`N-1:0];
X_C_PACKET condition_pack, condition_pack_n;

ROB_IDX index_finished;
PRF_IDX tag_finished;
logic start_mult, done_mult;
DATA rs1_mult,rs2_mult, rs1_cond, rs2_cond, result_mult;
MULT_FUNC func_mult;
ALU_FUNC func1_alu,func2_alu;
logic take;
DATA opa1_alu,opb1_alu,opa2_alu,opb2_alu,result1_alu,result2_alu;
logic [2:0] func_cond;

mult  mult1(
    .clock(clock), 
    .reset(reset), 
    .start(start_mult),
    .rs1(rs1_mult), 
    .rs2(rs2_mult),
    .func(func_mult),
    // input logic [TODO] dest_tag_in,

    // output logic [TODO] dest_tag_out,
    .result(result_mult),
    .done(done_mult)
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

logic   ['N:0]   mis_direction;
logic   ['N:0]   mis_target;



ADDR ['N:0] a, b;
 always_comb begin
        b = '0;
        for (int i = 0; i < `N+1; i++) begin
            logic is_branch;
            logic actual_taken;

            // A branch if either unconditional or conditional flag is set
            is_branch = s_x_pack[i].uncond_branch ||
                        s_x_pack[i].cond_branch;

            // Compute actual branch outcome
            //   - unconditional branches always take
            //   - conditional branches take based on comparator result
            actual_taken = s_x_pack[i].uncond_branch ||
                        (s_x_pack[i].cond_branch && take);

            // Direction mispredict:
            // Occurs when the predicted taken/not-taken disagrees with actual outcome
            mis_direction[i] = is_branch &&
                            (s_x_pack[i].predicted_taken != actual_taken);

            // Target mispredict:
            // Occurs only when BOTH prediction and actual take the branch,
            // but the predicted target address differs from the computed one
            a[i] = s_x_pack[i].predict_addr;

            case(i)
                3'd0:b[i] = result1_alu;
                3'd1:b[i] = result2_alu;
            endcase

            mis_target[i] = is_branch &&
                s_x_pack[i].predict_taken &&
                actual_taken &&
                (a[i]!= b[i]);
            
        end
    end


always_comb begin
    mispredicted = '0;
    mispredicted_bmask_index_n = '0;
    resolved = 'd1;
    resolved_bmask_index_n = '1;

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
    xc_pack_n = '0;
    condition_pack_n = '0;

    //input to units
    //third pack decide branch
    if (s_x_pack[`N].valid != '0 && s_x_pack[`N].cond_branch) begin
        rs1_cond = s_x_pack[`N].rs1_value;
        rs2_cond = s_x_pack[`N].rs1_value;
        func_cond = s_x_pack['N].inst.b.funct3;
    end


    //first pack decide mult or alu
    if (s_x_pack[0].valid != '0 && s_x_pack[0].mult ) begin
        rs1_mult = s_x_pack[0].rs1_value;
        rs2_mult = s_x_pack[0].rs2_value;
        func_mult = s_x_pack[0].inst.r.funct3;
        start_mult = '1;

    end else if (s_x_pack[0].valid != '0) begin
        func1_alu = s_x_pack[0].alu_func;
        case(s_x_pack[0].opa1_alu) 
            OPA_IS_RS1:  opa1_alu = s_x_pack[0].rs1_value;
            OPA_IS_NPC:  opa1_alu = s_x_pack[0].NPC;    //npc
            OPA_IS_PC:   opa1_alu = s_x_pack[0].PC;    //pc
            OPA_IS_ZERO: opa1_alu = 0;
            default:     opa1_alu = 32'hdeadface; // dead face
        endcase
        case(s_x_pack[0].opb1_alu) 
            OPB_IS_RS2:   opb1_alu = forwarding2;
            OPB_IS_I_IMM: opb1_alu = `RV32_signext_Iimm(s_x_pack[0].inst);
            OPB_IS_S_IMM: opb1_alu = `RV32_signext_Simm(s_x_pack[0].inst);
            OPB_IS_B_IMM: opb1_alu = `RV32_signext_Bimm(s_x_pack[0].inst);
            OPB_IS_U_IMM: opb1_alu = `RV32_signext_Uimm(s_x_pack[0].inst);
            OPB_IS_J_IMM: opb1_alu = `RV32_signext_Jimm(s_x_pack[0].inst);
            default:      opb1_alu = 32'hfacefeed; // face feed
        endcase
    end

    // second pack decide alu
    if (s_x_pack[`N-1].valid != '0 ) begin
            if (s_x_pack[0].valid && !s_x_pack[0].mult) begin

            func2_alu = s_x_pack[1].alu_func;
            case(s_x_pack[`N-1].opa_select) 
                OPA_IS_RS1:  opa2_alu = s_x_pack[1].rs1_value;
                OPA_IS_NPC:  opa2_alu = s_x_pack[1].NPC;    //npc
                OPA_IS_PC:   opa2_alu = s_x_pack[1].PC;    //pc
                OPA_IS_ZERO: opa2_alu = 0;
                default:     opa2_alu = 32'hdeadface; // dead face
            endcase
            case(s_x_pack[`N-1].opb_select) 
                OPB_IS_RS2:   opb2_alu = forwarding2;
                OPB_IS_I_IMM: opb2_alu = `RV32_signext_Iimm(s_x_pack[1].inst);
                OPB_IS_S_IMM: opb2_alu = `RV32_signext_Simm(s_x_pack[1].inst);
                OPB_IS_B_IMM: opb2_alu = `RV32_signext_Bimm(s_x_pack[1].inst);
                OPB_IS_U_IMM: opb2_alu = `RV32_signext_Uimm(s_x_pack[1].inst);
                OPB_IS_J_IMM: opb2_alu = `RV32_signext_Jimm(s_x_pack[1].inst);
                default:      opb2_alu = 32'hfacefeed; // face feed
            endcase

            end else begin
            func1_alu = s_x_pack[1].alu_func;
            case(s_x_pack[`N-1].opa_select) 
                OPA_IS_RS1:  opa1_alu = s_x_pack[1].rs1_value;
                OPA_IS_NPC:  opa1_alu = s_x_pack[1].NPC;    //npc
                OPA_IS_PC:   opa1_alu = s_x_pack[1].PC;    //pc
                OPA_IS_ZERO: opa1_alu = 0;
                default:     opa1_alu = 32'hdeadface; // dead face
            endcase
            case(s_x_pack[`N-1].opb_select) 
                OPB_IS_RS2:   opb1_alu = forwarding2;
                OPB_IS_I_IMM: opb1_alu = `RV32_signext_Iimm(s_x_pack[1].inst);
                OPB_IS_S_IMM: opb1_alu = `RV32_signext_Simm(s_x_pack[1].inst);
                OPB_IS_B_IMM: opb1_alu = `RV32_signext_Bimm(s_x_pack[1].inst);
                OPB_IS_U_IMM: opb1_alu = `RV32_signext_Uimm(s_x_pack[1].inst);
                OPB_IS_J_IMM: opb1_alu = `RV32_signext_Jimm(s_x_pack[1].inst);
                default:      opb1_alu = 32'hfacefeed; // face feed
            endcase
            end
        end

    //output from units
    if (s_x_pack[0].valid ) begin
    xc_pack_n[0].valid = 1  ;
    xc_pack_n[0].complete_index = s_x_pack[0].rob_index;
    xc_pack_n[0].complete_tag =  s_x_pack[0].tag;
    xc_pack_n[0].mispredict =  mis_direction[0] || mis_target[0];
    xc_pack_n[0].bmask_index =  xc_pack[0].bmask_index;
    xc_pack_n[0].result =  (!xc_pack[0].valid) ? '0: (xc_pack[0].mult) ? result_mult: result1_alu;
    end

    if (s_x_pack[1].valid) begin
    xc_pack_n[1].valid = 1;
    xc_pack_n[1].complete_index =  s_x_pack[1].rob_index;
    xc_pack_n[1].complete_tag =  s_x_pack[1].tag;
    xc_pack_n[1].mispredict =  mis_direction[1] || mis_target[1];
    xc_pack_n[1].bmask_index =  xc_pack[1].bmask_index;
    xc_pack_n[1].result =   (!xc_pack[1].valid) ? '0:(xc_pack[0].mult)? result1_alu:result2_alu; 
    end

    if (s_x_pack[2].valid) begin
    condition_pack_n.valid = 1;
    condition_pack_n.complete_index =  s_x_pack[2].rob_index;
    condition_pack_n.complete_tag =  s_x_pack[2].tag;
    condition_pack_n.mispredict =  mis_direction[2] || mis_target[2];
    condition_pack_n.bmask_index =  xc_pack[2].bmask_index;
    condition_pack_n.result =  take;     // if result is 1, it means taken, if 0 not taken, specify this in cpu.sv
    end
//   branch resolve logic //
////////////////////////////////////////////
//////////////////////////////////////////
/////////////////////////////////////////////

    // if (resolved && !mispredicted) begin
    //         for (int j = 0; j < `N; j++) begin
    //             if (xc_pack[j].valid) begin
    //                 xc_pack_n[j].bmask_index = xc_pack[j].bmask_index & ~(resolved_bmask_index);
    //             end
    //         end
    //     end
    // if (mispredicted) begin
    //         for (int j = 0; j < `N; j++) begin
    //             if (xc_pack[j].valid && (xc_pack[j].bmask_index & mispredicted_bmask_index)) begin
    //                 xc_pack_n[j]  = '0;
    //             end
    //         end
    //     end
    // end
        

        //compare the sequence of 3 instructions in order to define the mispredict bmaks and resolved bmask
    X_C_PACKET seq0, seq1, seq2;
    X_C_PACKET sequenced_packet[2:0];
    
    seq0 = xc_pack_n[0];
    seq1 = xc_pack_n[1];
    seq2 = condition_pack_n;
    if (seq0.bmask_index > seq1.bmask_index) begin
        X_C_PACKET tmp = seq0;
        seq0 = seq1;
        seq1 = tmp;
    end
    if (seq1.bmask_index > seq2.bmask_index) begin
        X_C_PACKET tmp = seq1;
        seq1 = seq2;
        seq2 = tmp;
    end

    if (seq0.bmask_index > seq1.bmask_index) begin
        X_C_PACKET tmp = seq0;
        seq0 = seq1;
        seq1 = tmp;
     end

    sequenced_packet[0] = seq0; // oldest
    sequenced_packet[1] = seq1;
    sequenced_packet[2] = seq2; // newest

    int mis_index;
    for (int i = 0; i < 3; i++) begin
        if (sequenced_packet[i].mispredict  && sequenced_packet[i].valid) begin
            mispredicted_bmask_index_n = sequenced_packet[i].bmask_index;
            mispredicted = 'd1;
            resolved = '0;
            mis_index = i;
            break;    
    end 
    end
    if (resolved) begin
        resolved_bmask_index_n = sequenced_packet[0].bmask_index | sequenced_packet[1].bmask_index | sequenced_packet[2].bmask_index;
    end


 // first, second or third one has mispredict
    if (mispredicted) begin
        for (int j = mis_index; j <3; j ++) begin
            if (sequenced_packet[j].bmask_index == xc_pack_n[0].bmask_index)
                xc_pack_n[0]='0;
            if (sequenced_packet[j].bmask_index == xc_pack_n[1].bmask_index)
                xc_pack_n[1]='0; 
            if (sequenced_packet[j].bmask_index == condition_pack_n.bmask_index)
                condition_pack_n='0;

    end
    end

end


always @(posedge clock) begin
    if(reset) begin
        xc_pack[`N-1:0] <= '{default:'0};
        condition_pack <= '{default:'0};
        mispredicted_bmask_index <=  '{default:'0};
        resolved_bmask_index <= '{default:'1};
    end
    else begin
        xc_pack[`N-1:0] <= xc_pack_n[`N-1:0];
        condition_pack <= condition_pack_n;
        mispredicted_bmask_index <= mispredicted_bmask_index_n;
        resolved_bmask_index <= resolved_bmask_index_n;
    end
end



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



