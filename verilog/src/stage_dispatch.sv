`include "sys_defs.svh"
module dispatcher (
    input logic                             clock                               , 
    input logic                             reset                               , 
    input F_D_PACKET                        f_d_pack                    [`N-1:0], // from fetch buffer
    input logic   [$clog2(`RS_SZ + 1)-1:0]  empty_entries_num                   , // from RS
    input ROB_CNT                           space_avail                         , // from ROB
    //from freelist
    input PRF_IDX                           t_new                       [`N-1:0], // from freelist
    input logic   [`N-1:0]                  avail_num                           , // from freelist   
    output logic  [`N-1:0]                  dispatch_valid                      , // to freelist
                       
    input X_C_PACKET                        cdb                         [`N-1:0], // updating map table ready bit
    
    //For branch resolve
    input logic                             resolved                            ,
    input X_C_PACKET                        resolved_bmask_index                ,
    //For branch mispredict
    input logic                             mispredicted                        ,
    input B_MASK                            mispredicted_bmask_index            ,

    output D_S_PACKET                       dispatch_pack               [`N-1:0],

    input  logic [`MT_SIZE-1:0]             maptable_snapshot_in                ,                         
    output logic [`MT_SIZE-1:0]             maptable_snapshot_out       [`N-1:0],

    output  ADDR                            pc_snapshot                 [`N-1:0],
    output  B_MASK                          branch_index                [`N-1:0],                
);

    typedef struct packed {
    ALU_OPA_SELECT opa_select,
    ALU_OPB_SELECT opb_select,
    logic          has_dest, // if there is a destination register
    ALU_FUNC       alu_func,
    logic          mult, rd_mem, wr_mem, cond_branch, uncond_branch,
    logic          csr_op, // used for CSR operations, we only use this as a cheap way to get the return code out
    logic          halt,   // non-zero on a halt
    logic          illegal
    }DECODE_PACKET;

    DECODE_PACKET [`N-1:0] decode_pack;
    PRF_IDX       [`N-1:0] t1, t2, told;
    logic         [`N-1:0] t1_ready, t2_ready;
    logic         [`MT_SIZE-1:0] [`N-1:0] maptable_snapshot_out;
    


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

    RED_IDX [`N-1:0] r1, r2, rd;
    ALU_OPA_SELECT [`N-1:0] opa_select;
    ALU_OPB_SELECT [`N-1:0] opb_select; 
    logic [`N-1:0] has_dest, cond_branch, halt;

    maptable maptable0(
        .clock                  (clock),
        .reset                  (reset),
        .mispredicted           (mispredicted),
        .opa_select             (),
        .opb_select             (),
        .has_dest               (),
        .cond_branch            (),
        .halt                   (),
        .cdb                    (),
        .t_from_freelist        (),
        .rd                     (),
        .r1                     (),
        .r2                     (),
        .snapshot_in            (),
        .t1                     (),
        .t2                     (),
        .told                   (),
        .t1_ready               (),
        .t2_ready               (),
        .snapshot_out           ()
    );



endmodule