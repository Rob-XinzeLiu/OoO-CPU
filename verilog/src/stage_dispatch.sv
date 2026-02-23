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
    output logic  [`N-1:0]                  dispatch_valid                      ,
                       
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
    output  logic [1:0]                     dispatch_num                        
);

    for (genvar i=0; i<`N; i++) begin : decoders
        decoder decoderN (
            .inst               (),
            .valid              (),
            .opa_select         (),
            .opb_select         (),
            .has_dest           (),
            .alu_func           (),
            .mult               (),
            .rd_mem             (),
            .wr_mem             (),
            .cond_branch        (),
            .uncond_branch      (),
            .csr_op             (),
            .halt               (),
            .illegal            ()
        );
    end

    maptable maptable0(
        .clock                  (clock),
        .reset                  (reset),
        .mispredicted           (),
        .branch_encountered     (),
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