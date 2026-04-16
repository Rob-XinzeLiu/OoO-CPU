`include "sys_defs.svh"

module load_queue(

    input  logic                  clock                         ,
    input  logic                  reset                         ,
    //from dispatch stage
    input  INST [`N-1:0]         inst_in                        ,
    input  logic [`N-1:0]        is_load                        ,
    input  logic [`N-1:0]        is_branch                      ,
    input  PRF_IDX [`N-1:0]      dest_tag_in                    ,
    //from rob
    input  ROB_IDX               rob_index              [`N-1:0],
    //from retire stage
    input  logic                 load_retire_valid              ,
    input  logic [1:0]           load_retire_num                ,
    //mispredict recovery
    input  logic                 mispredicted                   ,
    input  LQ_IDX                BS_lq_tail_in                  ,
    //store to load forwarding
    input ADDR                   sq_addr_in         [`SQ_SZ-1:0],
    input logic                  sq_addr_ready_in   [`SQ_SZ-1:0],
    input DATA                   sq_data_in         [`SQ_SZ-1:0],
    input logic                  sq_data_ready_in   [`SQ_SZ-1:0],
    input logic [`SQ_SZ-1:0]     sq_valid_in                    ,
    input logic [`SQ_SZ-1:0]     sq_valid_in_mask       [`N-1:0],
    input SQ_IDX                 sq_tail_in             [`N-1:0],
    input logic  [2:0]           sq_funct3_in         [`SQ_SZ-1:0],
    //the address calculated from execute stage
    input LQ_PACKET              load_execute_pack              ,
    //dcache can accept load
    input logic                  dcache_can_accept_load         ,
    //data from dcache
    input dcache_data_t          dcache_load_packet             ,

    //to dispatch stage, then go to rs & rob
    output LQ_IDX                lq_index               [`N-1:0],
    //output snapshot to branch stack
    output LQ_IDX                BS_lq_tail_out         [`N-1:0],
    //dispatch stage
    output logic [1:0]           lq_space_available             ,
    //to dcache
    output LQ_PACKET             load_packet                    ,
    //broadcast request
    output logic                 cdb_req_load                   ,
    //output to execute stage for broadcast
    output LQ_PACKET             lq_out

);

    typedef struct packed {
        logic         valid;
        ADDR          addr;
        logic         addr_ready;
        DATA          data;
        logic         data_ready;
        PRF_IDX       dest_tag;
        logic  [2:0]  funct3;
        logic [`SQ_SZ-1:0] old_sq_valid_mask;
        SQ_IDX        sq_tail_position;
        logic         issued;
        ROB_IDX       rob_index;
        logic         broadcasted;
        logic [1:0]   generation;
    } LQ_ENTRY;

    LQ_ENTRY    lq      [`LQ_SZ-1:0];
    LQ_ENTRY    lq_n    [`LQ_SZ-1:0];
    logic full, full_n;
    LQ_IDX      head, head_next;
    LQ_IDX      tail, tail_next;
    LQ_CNT      free_slots;

    // forwarding signals
    logic [`SQ_SZ-1:0]   addr_match_mask  [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   conflict_mask    [`LQ_SZ-1:0];
    logic                conflict_arr     [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   fwd_mask_arr     [`LQ_SZ-1:0];
    logic [2*`SQ_SZ-1:0] doubled          [`LQ_SZ-1:0];
    logic [2*`SQ_SZ-1:0] shifted          [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   shifted_trunc    [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   reversed         [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   reversed_neg     [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   lowest_of_rev    [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0]   highest_mask     [`LQ_SZ-1:0];
    logic                fwd_hit_arr      [`LQ_SZ-1:0];
    DATA                 fwd_data_arr     [`LQ_SZ-1:0];
    SQ_IDX               highest_idx      [`LQ_SZ-1:0];

    // per-entry to avoid shared variable issues
    SQ_IDX       selected_idx      [`LQ_SZ-1:0];
    logic        store_covers_load [`LQ_SZ-1:0];
    logic [3:0]  store_byte_mask   [`LQ_SZ-1:0];
    logic [3:0]  load_byte_mask    [`LQ_SZ-1:0];
    logic [7:0]  fwd_byte          [`LQ_SZ-1:0];
    logic [15:0] fwd_half          [`LQ_SZ-1:0];
    logic [31:0] mem_word          [`LQ_SZ-1:0];

    logic         dcache_req_done;
    LQ_IDX        dcache_req_idx;
    LQ_PACKET     lq_out_r, lq_out_next;
    assign lq_out = lq_out_r;

    logic head_moved;
    logic bcast_done;

    always_comb begin
        // defaults
        head_next       = head;
        tail_next       = tail;
        full_n          = full;
        lq_n            = lq;
        load_packet     = '0;
        lq_out_next     = '0;
        head_moved      = '0;
        cdb_req_load    = '0;
        lq_index        = '{default: '0};
        BS_lq_tail_out  = '{default: '0};
        dcache_req_idx  = '0;
        dcache_req_done = '0;

        for (int i = 0; i < `LQ_SZ; i++) begin
            addr_match_mask[i]   = '0;
            conflict_mask[i]     = '0;
            conflict_arr[i]      = '0;
            fwd_mask_arr[i]      = '0;
            doubled[i]           = '0;
            shifted[i]           = '0;
            shifted_trunc[i]     = '0;
            reversed[i]          = '0;
            reversed_neg[i]      = '0;
            lowest_of_rev[i]     = '0;
            highest_mask[i]      = '0;
            fwd_hit_arr[i]       = '0;
            fwd_data_arr[i]      = '0;
            highest_idx[i]       = '0;
            selected_idx[i]      = '0;
            store_byte_mask[i]   = '0;
            load_byte_mask[i]    = '0;
            store_covers_load[i] = '0;
            fwd_byte[i]          = '0;
            fwd_half[i]          = '0;
            mem_word[i]          = '0;
        end

        //----------------------------------------------------
        // retire logic
        //----------------------------------------------------
        if(load_retire_valid)begin
            if(load_retire_num==2)begin
                lq_n[head].valid = '0;
                lq_n[LQ_IDX'(head+1)].valid = '0;
                head_next = head + 2;
            end else begin
                lq_n[head].valid = '0;
                head_next = head + 1;
            end
        end

        //----------------------------------------------------
        // broadcast
        //----------------------------------------------------
        bcast_done = 1'b0;
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (!bcast_done) begin
                if (lq[LQ_IDX'(head+i)].valid
                 && lq[LQ_IDX'(head+i)].data_ready
                 && lq[LQ_IDX'(head+i)].addr_ready
                 && !lq[LQ_IDX'(head+i)].broadcasted) begin
                    cdb_req_load                       = 1'b1;
                    lq_out_next.valid                  = 1'b1;
                    lq_out_next.dest_tag               = lq[LQ_IDX'(head+i)].dest_tag;
                    lq_out_next.data                   = lq[LQ_IDX'(head+i)].data;
                    lq_out_next.rob_index              = lq[LQ_IDX'(head+i)].rob_index;
                    lq_n[LQ_IDX'(head+i)].broadcasted = 1'b1;
                    bcast_done                         = 1'b1;
                end
            end
        end

        //----------------------------------------------------
        // step1: fwd_mask = older stores still in SQ
        //----------------------------------------------------
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (lq[i].valid && lq[i].addr_ready && !lq[i].data_ready) begin
                fwd_mask_arr[i] = lq[i].old_sq_valid_mask & sq_valid_in;
            end
        end

        //----------------------------------------------------
        // step2: addr_match_mask + conflict_mask
        //----------------------------------------------------
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (lq[i].valid && lq[i].addr_ready && !lq[i].data_ready) begin
                for (int j = 0; j < `SQ_SZ; j++) begin
                    if (fwd_mask_arr[i][j] && sq_addr_ready_in[j]) begin
                        if (sq_addr_in[j][31:2] == lq[i].addr[31:2]) begin
                            // word-aligned match: potential conflict or forward
                            conflict_mask[i][j] = 1'b1;
                            `ifdef FWD_NONE
                                // never forward
                            `elsif FWD_WORD
                                addr_match_mask[i][j] = (sq_funct3_in[j][1:0] == 2'b10)
                                                     && (lq[i].funct3[1:0] == 2'b10)
                                                     && (sq_addr_in[j] == lq[i].addr);
                            `else
                                addr_match_mask[i][j] = 1'b1;
                            `endif
                        end
                        // no word-aligned match: no conflict, no forward
                    end
                end
            end
        end

        //----------------------------------------------------
        // step3: find youngest matching store, forwarding
        //----------------------------------------------------
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (lq[i].valid && lq[i].addr_ready && !lq[i].data_ready && |addr_match_mask[i]) begin
                doubled[i]       = {addr_match_mask[i], addr_match_mask[i]};
                shifted[i]       = doubled[i] >> lq[i].sq_tail_position;
                shifted_trunc[i] = shifted[i][`SQ_SZ-1:0];

                // bit-reverse shifted_trunc so that the youngest store (closest to tail)
                // maps to the lowest bit
                for (int k = 0; k < `SQ_SZ; k++) begin
                    reversed[i][k] = shifted_trunc[i][`SQ_SZ-1-k];
                end
                // x & (-x) extracts the lowest set bit in the reversed vector,
                // which corresponds to the youngest matching store
                reversed_neg[i] = ~reversed[i] + 1'b1;
                lowest_of_rev[i] = reversed[i] & reversed_neg[i];
                // bit-reverse back to recover the original index space
                for (int k = 0; k < `SQ_SZ; k++) begin
                    highest_mask[i][k] = lowest_of_rev[i][`SQ_SZ-1-k];
                end

                for (int j = 0; j < `SQ_SZ; j++) begin
                    if (highest_mask[i][j])
                        highest_idx[i] = SQ_IDX'(j);
                end

                selected_idx[i] = SQ_IDX'(highest_idx[i] + lq[i].sq_tail_position);

                if (sq_data_ready_in[selected_idx[i]]) begin
                    `ifdef FWD_NONE
                        // never forward, conflict_mask handles stall
                    `elsif FWD_WORD
                        fwd_hit_arr[i]  = 1'b1;
                        fwd_data_arr[i] = sq_data_in[selected_idx[i]];
                    `else
                        // byte level: compute store/load byte masks
                        case (sq_funct3_in[selected_idx[i]][1:0])
                            2'b00:   store_byte_mask[i] = 4'b0001 << sq_addr_in[selected_idx[i]][1:0];
                            2'b01:   store_byte_mask[i] = 4'b0011 << sq_addr_in[selected_idx[i]][1:0];
                            2'b10:   store_byte_mask[i] = 4'b1111;
                            default: store_byte_mask[i] = 4'b0000;
                        endcase

                        case (lq[i].funct3[1:0])
                            2'b00:   load_byte_mask[i] = 4'b0001 << lq[i].addr[1:0];
                            2'b01:   load_byte_mask[i] = 4'b0011 << lq[i].addr[1:0];
                            2'b10:   load_byte_mask[i] = 4'b1111;
                            default: load_byte_mask[i] = 4'b0000;
                        endcase

                        store_covers_load[i] = ((store_byte_mask[i] & load_byte_mask[i])
                                                == load_byte_mask[i]);

                        if (store_covers_load[i]) begin
                            fwd_hit_arr[i] = 1'b1;

                            // reconstruct memory word from store data
                            // store data is always in low bits of sq_data_in
                            // need to place it at correct byte position
                            case (sq_funct3_in[selected_idx[i]][1:0])
                                2'b00: begin // sb: 1 byte in low 8 bits
                                    mem_word[i] = '0;
                                    case (sq_addr_in[selected_idx[i]][1:0])
                                        2'b00: mem_word[i][7:0]   = sq_data_in[selected_idx[i]][7:0];
                                        2'b01: mem_word[i][15:8]  = sq_data_in[selected_idx[i]][7:0];
                                        2'b10: mem_word[i][23:16] = sq_data_in[selected_idx[i]][7:0];
                                        2'b11: mem_word[i][31:24] = sq_data_in[selected_idx[i]][7:0];
                                        default: mem_word[i][7:0] = sq_data_in[selected_idx[i]][7:0];
                                    endcase
                                end
                                2'b01: begin // sh: 2 bytes in low 16 bits
                                    mem_word[i] = '0;
                                    case (sq_addr_in[selected_idx[i]][1])
                                        1'b0: mem_word[i][15:0]  = sq_data_in[selected_idx[i]][15:0];
                                        1'b1: mem_word[i][31:16] = sq_data_in[selected_idx[i]][15:0];
                                        default: mem_word[i][15:0] = sq_data_in[selected_idx[i]][15:0];
                                    endcase
                                end
                                2'b10: begin // sw: full word
                                    mem_word[i] = sq_data_in[selected_idx[i]];
                                end
                                default: mem_word[i] = sq_data_in[selected_idx[i]];
                            endcase

                            // extract load data from reconstructed mem_word
                            case (lq[i].funct3[1:0])
                                2'b00: begin // lb/lbu
                                    case (lq[i].addr[1:0])
                                        2'b00:   fwd_byte[i] = mem_word[i][7:0];
                                        2'b01:   fwd_byte[i] = mem_word[i][15:8];
                                        2'b10:   fwd_byte[i] = mem_word[i][23:16];
                                        2'b11:   fwd_byte[i] = mem_word[i][31:24];
                                        default: fwd_byte[i] = mem_word[i][7:0];
                                    endcase
                                    fwd_data_arr[i] = lq[i].funct3[2] ?
                                                      {24'b0, fwd_byte[i]} :
                                                      {{24{fwd_byte[i][7]}}, fwd_byte[i]};
                                end
                                2'b01: begin // lh/lhu
                                    case (lq[i].addr[1])
                                        1'b0:    fwd_half[i] = mem_word[i][15:0];
                                        1'b1:    fwd_half[i] = mem_word[i][31:16];
                                        default: fwd_half[i] = mem_word[i][15:0];
                                    endcase
                                    fwd_data_arr[i] = lq[i].funct3[2] ?
                                                      {16'b0, fwd_half[i]} :
                                                      {{16{fwd_half[i][15]}}, fwd_half[i]};
                                end
                                2'b10: begin // lw
                                    fwd_data_arr[i] = mem_word[i];
                                end
                                default: fwd_data_arr[i] = mem_word[i];
                            endcase
                        end
                        // if !store_covers_load: conflict_mask handles stall
                    `endif
                end
                // if !sq_data_ready: conflict_mask handles stall
            end
        end

        //----------------------------------------------------
        // step4: set conflict_arr
        //----------------------------------------------------
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (lq[i].valid && lq[i].addr_ready && !lq[i].data_ready) begin
                if (|conflict_mask[i] && !fwd_hit_arr[i]) begin
                    conflict_arr[i] = 1'b1;
                end
            end
        end

        //----------------------------------------------------
        // step5: apply forwarding
        //----------------------------------------------------
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (fwd_hit_arr[i]) begin
                lq_n[i].data       = fwd_data_arr[i];
                lq_n[i].data_ready = 1'b1;
            end
        end

        //----------------------------------------------------
        // dcache request, start from head
        //----------------------------------------------------
        dcache_req_done = 1'b0;
        for (int i = 0; i < `LQ_SZ; i++) begin
            if (!dcache_req_done) begin
                dcache_req_idx = LQ_IDX'(head + i);
                if (lq[dcache_req_idx].valid
                 && lq[dcache_req_idx].addr_ready
                 && dcache_can_accept_load
                 && !lq[dcache_req_idx].data_ready
                 && !lq[dcache_req_idx].issued
                 && !fwd_hit_arr[dcache_req_idx]
                 && !conflict_arr[dcache_req_idx]
                 && lq[dcache_req_idx].addr < `MEM_SIZE_IN_BYTES) begin
                    load_packet.valid           = 1'b1;
                    load_packet.addr            = lq[dcache_req_idx].addr;
                    load_packet.lq_index        = dcache_req_idx;
                    load_packet.funct3          = lq[dcache_req_idx].funct3;
                    load_packet.generation      = lq[dcache_req_idx].generation;
                    lq_n[dcache_req_idx].issued = 1'b1;
                    dcache_req_done             = 1'b1;
                end
            end
        end

        //----------------------------------------------------
        // dcache return writeback
        //----------------------------------------------------
        if (dcache_load_packet.valid
         && lq_n[dcache_load_packet.lq_index].valid
         && lq_n[dcache_load_packet.lq_index].issued
         && dcache_load_packet.generation == lq_n[dcache_load_packet.lq_index].generation) begin
            lq_n[dcache_load_packet.lq_index].data       = dcache_load_packet.data;
            lq_n[dcache_load_packet.lq_index].data_ready = 1'b1;
            lq_n[dcache_load_packet.lq_index].issued     = 1'b0;
        end

        //----------------------------------------------------
        // fill address from execute stage
        //----------------------------------------------------
        if (load_execute_pack.valid && lq[load_execute_pack.lq_index].valid) begin
            lq_n[load_execute_pack.lq_index].addr       = load_execute_pack.addr;
            lq_n[load_execute_pack.lq_index].addr_ready = 1'b1;
        end

        //----------------------------------------------------
        // dispatch / mispredict recovery
        //----------------------------------------------------
        if (mispredicted) begin
            tail_next = BS_lq_tail_in;
            for (int i = 0; i < `LQ_SZ; i++) begin
                if (full && tail == BS_lq_tail_in) begin
                    lq_n[i].valid = '0;
                end else if (BS_lq_tail_in <= tail) begin
                    if (i >= BS_lq_tail_in && i < tail)
                        lq_n[i].valid = '0;
                end else begin
                    if (i >= BS_lq_tail_in || i < tail)
                        lq_n[i].valid = '0;
                end
            end
        end else begin
            for (int i = 0; i < `N; i++) begin
                if (is_load[i]) begin
                   lq_n[tail_next] = '{
                        valid:             1'b1,
                        dest_tag:          dest_tag_in[i],
                        funct3:            inst_in[i].i.funct3,
                        old_sq_valid_mask: sq_valid_in_mask[i],
                        sq_tail_position:  sq_tail_in[i],
                        rob_index:         rob_index[i],
                        generation:        lq[tail_next].generation + 1,  
                        addr:              '0,
                        addr_ready:        1'b0,
                        data:              '0,
                        data_ready:        1'b0,
                        issued:            1'b0,
                        broadcasted:       1'b0
                    };
                    lq_index[i]                       = tail_next;
                    tail_next                         = tail_next + 1;
                end
                if (is_branch[i]) begin
                    BS_lq_tail_out[i] = tail_next;
                end
            end
        end

        //----------------------------------------------------
        // available space
        //----------------------------------------------------
        if (head_next == tail_next) begin
            if (head_moved) begin
                full_n = 1'b0;
            end else if (mispredicted) begin
                full_n = 1'b0;
            end else if (head_next == head && tail_next == tail) begin
                full_n = full;
            end else begin
                full_n = (tail_next != tail) && (head_next == head);
            end
        end else begin
            full_n = 1'b0;
        end

        free_slots = full_n ? '0 :
                     (head_next == tail_next) ? `LQ_SZ :
                     (head_next > tail_next)  ? LQ_IDX'(head_next - tail_next) :
                                                LQ_IDX'(`LQ_SZ - (tail_next - head_next));

        lq_space_available = full_n                  ? 2'd0 :
                             (head_next == tail_next) ? 2'd2 :
                             (free_slots >= 2)        ? 2'd2 :
                             (free_slots == 1)        ? 2'd1 : 2'd0;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            head     <= '0;
            tail     <= '0;
            lq       <= '{default:'0};
            lq_out_r <= '0;
            full     <= '0;
        end else begin
            head     <= head_next;
            tail     <= tail_next;
            lq       <= lq_n;
            lq_out_r <= lq_out_next;
            full     <= full_n;
        end
    end

endmodule