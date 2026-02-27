`include "sys_defs.svh"

module maptable(
    input logic                         clock,
    input logic                         reset,
    input logic                         mispredicted,
    input ALU_OPA_SELECT                opa_select              [`N-1:0],  // Whether to read src1 mapping
    input ALU_OPB_SELECT                opb_select              [`N-1:0],  // Whether to read src2 mapping
    input logic                         has_dest                [`N-1:0],
    input logic                         cond_branch             [`N-1:0],
    input logic                         halt                    [`N-1:0],
    input X_C_PACKET                    cdb                     [`N-1:0],
    input PRF_IDX                       t_from_freelist         [`N-1:0],
    input REG_IDX                       rd                      [`N-1:0],
    input REG_IDX                       r1                      [`N-1:0],
    input REG_IDX                       r2                      [`N-1:0],
    input logic [`MT_SIZE-1:0]          snapshot_in                     ,
    input logic                         is_branch               [`N-1:0],
    
    output  PRF_IDX                     t1                      [`N-1:0],
    output  PRF_IDX                     t2                      [`N-1:0],
    output  PRF_IDX                     told                    [`N-1:0],
    output  logic                       t1_ready                [`N-1:0],
    output  logic                       t2_ready                [`N-1:0],
    output  logic [`MT_SIZE-1:0]        snapshot_out            [`N-1:0]
);
    MT_ENTRY    [`ARCH_REG_SZ-1:0]          mt, next_mt, recovery_mt;
    logic       [`PHYS_REG_SZ_R10K-1:0]     prf_ready, next_prf_ready;


    localparam int ENTRY_LENGTH = $bits(`MT_ENTRY);

    // Snapshot: Pack
    function automatic logic [`MT_SIZE-1:0] pack_mt(input MT_ENTRY [`ARCH_REG_SZ-1:0] t);
        logic [`MT_SIZE-1:0] p;
        for (int i = 0; i < `ARCH_REG_SZ; i++) begin
            p[`MT_SIZE-1 - i*ENTRY_LENGTH -: ENTRY_LENGTH] = t[i];
        end
        return p;
    endfunction

    // Snapshot: Unpack
    function automatic  MT_ENTRY [`ARCH_REG_SZ-1:0] unpack_mt(input logic [`MT_SIZE-1:0] q);
        MT_ENTRY [`ARCH_REG_SZ-1:0] r;
        for(int i = 0; i < `ARCH_REG_SZ; i++) begin
            r[i] = q[`MT_SIZE-1 - i*ENTRY_LENGTH -: ENTRY_LENGTH];
        end
        return r;
    endfunction

///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Combinational Logic    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
    always_comb begin
        t1_ready    = 1'b1;
        t2_ready    = 1'b1;
        for(int i = 0; i < `N; i++) begin
            t1[i]           = '0;
            t2[i]           = '0;
            told[i]         = '0;
            snapshot_out[i] = '0;
        end

        next_mt = mt;
        next_prf_ready   = prf_ready;

        // CDB broadcasts
        for(int i = 0; i < `N; i++) begin
            if(cdb[i].valid) begin
                next_prf_ready[cdb[i].complete_tag] = 1'b1;
            end
        end

        // Mispredicted
        if(mispredicted) begin
            recovery_mt = unpack_mt(snapshot_in);
            for(int i = 0; i < `ARCH_REG_SZ; i++) begin
                next_mt[i].p_tag = recovery_mt;
                next_mt[i].ready = next_prf_ready[next_mt[i].p_tag]; 
            end
        end else begin          // read then write
            // Instruction 0
            if(!halt[0]) begin
                if(opa_select[0] == OPA_IS_RS1 && r1[0] != '0 && !halt || cond_branch[0]) begin
                    t1[0]       = mt[r1[0]].p_tag;
                    t1_ready[0] = next_prf_ready[t1[0]];
                end

                if(opb_select[0] == OPB_IS_RS2 && r2[0] != '0 && !halt || cond_branch[0]) begin
                    t2[0]       = mt[r2[0]].p_tag;
                    t2_ready[0] = next_prf_ready[t2[0]];
                end

                if(has_dest[0] && rd[0] != '0) begin
                    told[0]              = mt[rd[0]].p_tag;
                    next_mt[rd[0]].p_tag = t_from_freelist[0];
                    next_prf_ready[t_from_freelist[0]] = 1'b0;     // Clear ready bits
                end
            end

            // Take snapshot[0]
            if(is_branch[0]) begin
                snapshot_out[0] = pack_mt(next_mt);
            end

            // Instruction 1
            if (!halt[1]) begin
                if (opa_select[1] == OPA_IS_RS1 && r1[1] != '0 || cond_branch[1]) begin
                    if (has_dest[0] && rd[0] != '0 && r1[1] == rd[0]) begin
                        t1[1]       = t_from_freelist[0]; 
                        t1_ready[1] = 1'b0;              
                    end else begin
                        t1[1]       = mt[r1[1]].p_tag;    
                        t1_ready[1] = next_prf_ready[t1[1]];
                    end
                end

                if (opb_select[1] == OPB_IS_RS2 && r2[1] != '0 || cond_branch[1]) begin
                    if (has_dest[0] && rd[0] != '0 && r2[1] == rd[0]) begin
                        t2[1]       = t_from_freelist[0];
                        t2_ready[1] = 1'b0;
                    end else begin
                        t2[1]       = mt[r2[1]].p_tag;
                        t2_ready[1] = next_prf_ready[t2[1]];
                    end
                end

                if (has_dest[1] && rd[1] != '0) begin
                    told[1]              = next_mt[rd[1]].p_tag; // Check next_mt to prevent WAW
                    next_mt[rd[1]].p_tag = t_from_freelist[1];
                    next_prf_ready[t_from_freelist[1]] = 1'b0;
                end
            end

            // Take snapshot[1]
            if(is_branch[1]) begin
                snapshot_out[1] = pack_mt(next_mt);
            end
        end

        for (int i = 0; i < ARCH_REG_SZ; i++) begin
            next_mt[i].ready = next_prf_ready[next_mt[i].p_tag]; 
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
            prf_ready <= '0;

            for(int i = 0; i < `ARCH_REG_SZ; i++) begin
                prf_ready[PRF_IDX'(i)] <= 1'b1;
            end
        end else begin
            prf_ready <= next_prf_ready;
        end
    end

    // Update maptable
    always_ff @(posedge clock) begin
        if(reset) begin
            for(int i = 0; i < `ARCH_REG_SZ; i++) begin
                mt.p_tag <= PRF_IDX'(i);
                mt.ready <= 1'b1;
            end
        end else begin
            mt <= next_mt;
        end
    end
    
endmodule