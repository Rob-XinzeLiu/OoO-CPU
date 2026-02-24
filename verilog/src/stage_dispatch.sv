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
    input B_MASK                            mispredicted_bmask                  ,

    output D_S_PACKET                       dispatch_pack               [`N-1:0],
    output logic                            branch_encountered          [`N-1:0],

    input  logic [`MT_SIZE-1:0]             maptable_snapshot_in                ,                         
    output logic [`MT_SIZE-1:0]             maptable_snapshot_out       [`N-1:0],

    output ADDR                             pc_snapshot_out             [`N-1:0],
    output B_MASK                           branch_index                [`N-1:0],  
    output logic [1:0]                      dispatch_num             
);

    function automatic int unsigned min2(
        input int unsigned   a,
        input int unsigned   b
    );
        return (a < b) ? a : b;
    endfunction

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

    DECODE_PACKET   [`N-1:0]    decode_pack;

    RED_IDX [`N-1:0] r1, r2, rd;
    ALU_OPA_SELECT [`N-1:0] opa_select;
    ALU_OPB_SELECT [`N-1:0] opb_select; 
    logic [`N-1:0] has_dest, cond_branch, halt;

    PRF_IDX         [`N-1:0]    t1, t2, told;
    logic           [`N-1:0]    t1_ready, t2_ready;
    logic           [`MT_SIZE-1:0] [`N-1:0] snapshot_out;
    int unsigned      branch_count, next_branch_count;
    int unsigned      branch_avail_slot;
    int unsigned      small1, small2, small3;
    

    // Bmask
    B_MASK  bmask, next_bmask, bmask_idx_0, bmask_idx_1;
    logic   branch_dispatch_1, branch_dispatch_2;
    


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
        .t1                     (t1),
        .t2                     (t2),
        .told                   (told),
        .t1_ready               (t1_ready),
        .t2_ready               (t2_ready),
        .snapshot_out           (snapshot_out)
    );


    always_comb begin
        for(int i = 0; i < `N; i++) begin
            r1[i] = f_d_pack[i].inst.r.rs1;
            r2[i] = f_d_pack[i].inst.r.rs2;
            rd[i] = f_d_pack[i].inst.r.rd;
            opa_select[i] = decode_pack[i].opa_select;
            opb_select[i] = decode_pack[i].opb_select;
            has_dest[i] = decode_pack[i].has_dest;
            cond_branch[i] = decode_pack[i].cond_branch;
            halt[i] = decode_pack[i].halt;
        end
    end

    always_comb begin
        for(int i = 0; i < `N; i++) begin
            dispatch_valid[i] = f_d_pack[i].valid;
        end
    end

    always_comb begin
        for (int i = 0; i <`N; i++) begin
            pc_snapshot_out[i]           = (decode_pack[i].cond_branch && f_d_pack[i].valid )? f_d_pack[i].PC : '0;
        end
    end

    always_comb begin
        for (int i = 0; i < N; i++) begin
            mt_snapshot_out[i] = snapshot_out[i];
        end
    end

    always_comb begin
        dispatch_num = 0;
        next_branch_count = branch_count;
        dispatch_pack = '{default: '0};
        next_bmask = bmask;
        bmask_idx_0 = 'd0;
        bmask_idx_1 = 'd0;
        // Allocate bmask
        if(mispredicted) begin
            next_bmask = mispredicted_bmask;
            next_branch_count = $countone(next_bmask);
            for(int i = 0; i < 2*`N; i++) begin
                if(~next_bmask[i]) begin
                    bmask_idx_0[i] = 1'b1;
                    break;
                end
            end
            dispatch_num = 'd0;
        end else begin
            // resolve logic
            if(resolved) begin
                next_bmask = next_bmask & (~resolved_bmask_index);
            end
            // make branch_index to branch stack
            branch_dispatch_1 = (next_branch_count == 3 && (f_d_pack[0].valid && cond_branch[0] || f_d_pack[1].valid && cond_branch[1]));
            branch_dispatch_2 = (next_branch_count < 3  && f_d_pack[0].valid && cond_branch[0] && f_d_pack[1].valid && cond_branch[1]);
        
            if(branch_dispatch_1 && f_d_pack[0].valid && cond_branch[0]) begin
                for(int i = 0; i < 2*`N; i++) begin
                    if(~next_bmask[i]) begin
                        bmask_idx_0[i] = 1'b1;
                        break;
                    end
                end
                dispatch_pack[0].bmask = next_bmask;
            end else if(branch_dispatch_2) begin
                for(int i = 0; i < 2*`N; i++) begin
                    if(~next_bmask[i]) begin
                        bmask_idx_0[i] = 1'b1;
                        break;
                    end
                end
                dispatch_pack[0].bmask = next_bmask;
                next_bmask = next_bmask | bmask_idx_0;
                for(int i = 0; i < 2*`N; i++) begin
                    if(~next_bmask[i]) begin
                        bmask_idx_1[i] = 1'b1;
                        break;
                    end
                end
                dispatch_pack[1].bmask = next_bmask;
            end
            branch_index[0] = bmask_idx_0;
            branch_index[1] = bmask_idx_1;

            // Pack the dispatch_pack
            for(int i = 0; i < `N; i++) begin
                dispatch_pack[i].inst = f_d_pack[i].inst;
                dispatch_pack[i].valid = f_d_pack[i].valid;
                dispatch_pack[i].T = t_new[i];
                dispatch_pack[i].Told = told[i];
                dispatch_pack[i].t1 = t1[i];
                dispatch_pack[i].t2 = t2[i];
                dispatch_pack[i].t1_ready = t1_ready[i];
                dispatch_pack[i].t2_ready = t2_ready[i];
                dispatch_pack[i].PC = f_d_pack[i].PC;
                dispatch_pack[i].NPC = f_d_pack[i].NPC;
                dispatch_pack[i].opa_select = decode_pack[i].opa_select;
                dispatch_pack[i].opb_select = decode_pack[i].opb_select;
                dispatch_pack[i].has_dest = decode_pack[i].has_dest;
                dispatch_pack[i].alu_func = decode_pack[i].alu_func;
                dispatch_pack[i].mult = decode_pack[i].mult;
                dispatch_pack[i].rd_mem = decode_pack[i].rd_mem;
                dispatch_pack[i].wr_mem = decode_pack[i].wr_mem;
                dispatch_pack[i].cond_branch = decode_pack[i].cond_branch;
                dispatch_pack[i].uncond_branch = decode_pack[i].uncond_branch;
                dispatch_pack[i].csr_op = decode_pack[i].csr_op;
                dispatch_pack[i].halt = decode_pack[i].halt;
                dispatch_pack[i].illegal = decode_pack[i].illegal;
            end
            dispatch_pack[0].bmask_index = bmask_idx_0;
            dispatch_pack[1].bmask_index = bmask_idx_1 ;
        end
        
        
        // Calculate how many instructions we can dispatch 
        branch_avail_slot = (next_branch_count < 3)? 'd2:(next_branch_count == 3)? 'd1:'d0; // TODO: check timing
        small1 = min2(branch_avail_slot, empty_entries_num);
        small2 = min2(small1, space_avail);
        small3 = min2(small2, avail_num);
        dispatch_num = small3;
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

endmodule