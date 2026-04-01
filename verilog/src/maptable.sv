`include "sys_defs.svh"

module maptable(
    input logic                                         clock   ,
    input logic                                         reset   ,
    input logic                                         mispredicted,
    input ALU_OPA_SELECT[`N-1:0]                        opa_select             ,  // Whether to read src1 mapping
    input ALU_OPB_SELECT[`N-1:0]                        opb_select            ,  // Whether to read src2 mapping
    input logic         [`N-1:0]                        has_dest               ,
    input logic         [`N-1:0]                        cond_branch           ,
    input logic         [`N-1:0]                        halt                  ,
    input X_C_PACKET    [`N-1:0]                        cdb                    ,
    input PRF_IDX       [`N-1:0]                        t_from_freelist        ,
    input REG_IDX       [`N-1:0]                        rd                    ,
    input REG_IDX       [`N-1:0]                        r1                   ,
    input REG_IDX       [`N-1:0]                        r2                    ,
    input logic                 [`MT_SIZE-1:0]          snapshot_in                     ,
    input logic         [`N-1:0]                        is_branch             ,
    input logic         [`N-1:0]                        is_store               ,
    input logic         [`N-1:0]                        valid                 , 
    
    output  PRF_IDX     [`N-1:0]                        t1                  ,
    output  PRF_IDX     [`N-1:0]                        t2                 ,
    output  PRF_IDX     [`N-1:0]                        told                  ,
    output  logic       [`N-1:0]                        t1_ready         ,
    output  logic       [`N-1:0]                        t2_ready             ,
    output  logic       [`N-1:0][`MT_SIZE-1:0]          snapshot_out
);
    PRF_IDX    [`ARCH_REG_SZ-1:0]          mt, next_mt;
    logic       [`PHYS_REG_SZ_R10K-1:0]     prf_ready, next_prf_ready;


    localparam int TAG_LENGTH = $bits(PRF_IDX);

    // Snapshot: Pack
    function automatic logic [`MT_SIZE-1:0] pack_mt(input PRF_IDX [`ARCH_REG_SZ-1:0] t);
        logic [`MT_SIZE-1:0] p;
        for (int i = 0; i < `ARCH_REG_SZ; i++) begin
            p[`MT_SIZE-1 - i*TAG_LENGTH -: TAG_LENGTH] = t[i];
        end
        return p;
    endfunction

    // Snapshot: Unpack
    function automatic  PRF_IDX [`ARCH_REG_SZ-1:0] unpack_mt(input logic [`MT_SIZE-1:0] q);
        PRF_IDX [`ARCH_REG_SZ-1:0] r;
        for(int i = 0; i < `ARCH_REG_SZ; i++) begin
            r[i] = q[`MT_SIZE-1 - i*TAG_LENGTH -: TAG_LENGTH];
        end
        return r;
    endfunction

///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Combinational Logic    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
    always_comb begin
        t1_ready            = '1;
        t2_ready            = '1;
        t1                  = '0;
        t2                  = '0;
        told                = '0;
        snapshot_out        = '0;
        next_mt             = mt;
        next_prf_ready      = prf_ready;

        // CDB broadcasts
        for(int i = 0; i < `N; i++) begin
            if(cdb[i].valid) begin
                next_prf_ready[cdb[i].complete_tag] = 1'b1;
            end
        end

        // Mispredicted
        if(mispredicted) begin
            next_mt = unpack_mt(snapshot_in);
        end else begin          // read then write
            // Instruction 0
            if(!halt[0] && valid[0]) begin
                if((opa_select[0] == OPA_IS_RS1 && r1[0] != '0) || cond_branch[0]) begin
                    t1[0]       = mt[r1[0]];
                    t1_ready[0] = next_prf_ready[t1[0]];
                end

                if((opb_select[0] == OPB_IS_RS2 && r2[0] != '0 )|| cond_branch[0] || is_store[0]) begin
                    t2[0]       = mt[r2[0]];
                    t2_ready[0] = next_prf_ready[t2[0]];
                end

                if(has_dest[0] && rd[0] != '0) begin
                    told[0]              = mt[rd[0]];
                    next_mt[rd[0]] = t_from_freelist[0];
                    next_prf_ready[t_from_freelist[0]] = 1'b0;     // Clear ready bits
                end
            end

            // Take snapshot[0]
            if(is_branch[0] && valid[0]) begin
                snapshot_out[0] = pack_mt(next_mt);
            end

            // Instruction 1
            if (!halt[1] && valid[1]) begin
                if (opa_select[1] == OPA_IS_RS1 && r1[1] != '0 || cond_branch[1]) begin
                    if (has_dest[0] && rd[0] != '0 && r1[1] == rd[0]) begin
                        t1[1]       = t_from_freelist[0]; 
                        t1_ready[1] = 1'b0;              
                    end else begin
                        t1[1]       = mt[r1[1]];    
                        t1_ready[1] = next_prf_ready[t1[1]];
                    end
                end

                if (opb_select[1] == OPB_IS_RS2 && r2[1] != '0 || cond_branch[1] || is_store[1]) begin
                    if (has_dest[0] && rd[0] != '0 && r2[1] == rd[0]) begin
                        t2[1]       = t_from_freelist[0];
                        t2_ready[1] = 1'b0;
                    end else begin
                        t2[1]       = mt[r2[1]];
                        t2_ready[1] = next_prf_ready[t2[1]];
                    end
                end

                if (has_dest[1] && rd[1] != '0) begin
                    told[1]              = next_mt[rd[1]]; // Check next_mt to prevent WAW
                    next_mt[rd[1]] = t_from_freelist[1];
                    next_prf_ready[t_from_freelist[1]] = 1'b0;
                end
            end

            // Take snapshot[1]
            if(is_branch[1] && valid[1]) begin
                snapshot_out[1] = pack_mt(next_mt);
            end
        end
    end


///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Sequential Logic       ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////

    // Update prf scoreboard
    always_ff @(posedge clock) begin
        if(reset) begin
            prf_ready <= '0;//set all physical reg to not ready
            for(int i = 0; i < `ARCH_REG_SZ; i++) begin
                prf_ready[PRF_IDX'(i)] <= 1'b1;//set the original register to be ready
            end
        end else begin
            prf_ready <= next_prf_ready;
        end
    end

    // Update maptable
    always_ff @(posedge clock) begin
        if(reset) begin
            for(int i = 0; i < `ARCH_REG_SZ; i++) begin
                mt[i] <= PRF_IDX'(i);
            end
        end else begin
            mt <= next_mt;
        end
    end
    
endmodule