`include "sys_defs.svh"

module load_queue(

    input  logic                  clock,
    input  logic                  reset,
 
    //from dispatch stage
    input  INST       [`N-1:0]           inst_in                ,
    input  logic           [`N-1:0]        is_load              ,
    input  logic             [`N-1:0]      is_branch            ,
    input  PRF_IDX           [`N-1:0]     dest_tag_in           ,
    //from rob
    input  ROB_IDX               rob_index              [`N-1:0],
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
    input logic  [2:0]           sq_funct3_in         [`SQ_SZ-1:0],// forwarding
    input logic [`SQ_SZ-1:0]     sq_ready_retire_in             ,
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
    //output to execute stage for braodcast
    output LQ_PACKET             lq_out

);

    typedef struct packed {
        logic         valid ;     
        ADDR          addr ;  
        logic         addr_ready ; 
        DATA          data;  
        logic         data_ready ;   
        PRF_IDX       dest_tag;      
        logic  [2:0]   funct3;
        logic [`SQ_SZ-1:0] old_sq_valid_mask; 
        SQ_IDX         sq_tail_position; 
        logic          issued; // already request to dcache，waiting for data return    
        ROB_IDX         rob_index;    
    } LQ_ENTRY;

    LQ_ENTRY    lq          [`LQ_SZ-1:0];
    LQ_ENTRY    lq_n        [`LQ_SZ-1:0];
    logic full, full_n;
    LQ_IDX      head, head_next;
    LQ_IDX      tail, tail_next;
    LQ_CNT      free_slots;

    // forwarding 
    logic [`SQ_SZ-1:0]      addr_match_mask[`LQ_SZ-1:0];
    logic                   conflict_arr   [`LQ_SZ-1:0]; // the youngest older store doesn't have ready data
    logic [`SQ_SZ-1:0]       fwd_mask_arr  [`LQ_SZ-1:0];
    logic [2*`SQ_SZ-1:0]     doubled       [`LQ_SZ-1:0];
    logic [2*`SQ_SZ-1:0]     shifted       [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0] shifted_trunc       [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0] prefix_or           [`LQ_SZ-1:0];
    logic [`SQ_SZ-1:0] highest_mask        [`LQ_SZ-1:0];
    logic                    fwd_hit_arr   [`LQ_SZ-1:0];
    DATA                     fwd_data_arr  [`LQ_SZ-1:0];
    SQ_IDX highest_idx                     [`LQ_SZ-1:0];
    SQ_IDX selected_idx;
    logic store_covers_load;
    logic has_pending_store;

    LQ_IDX   dcache_req_idx;
    LQ_PACKET lq_out_r, lq_out_next;
    assign lq_out = lq_out_r;



    always_comb begin
        //default
        head_next = head;
        tail_next = tail;
        full_n   = full;
        lq_n = lq;
        load_packet = '0;
        lq_out_next = '0;
        cdb_req_load = '0;
        lq_index = '{default: '0};
        BS_lq_tail_out = '{default: '0};
        addr_match_mask  = '{default: '0};
        conflict_arr     = '{default: '0};
        fwd_mask_arr     = '{default: '0};
        doubled          = '{default: '0};
        shifted          = '{default: '0};
        shifted_trunc    = '{default: '0};
        prefix_or        = '{default: '0};
        highest_mask     = '{default: '0};
        fwd_hit_arr      = '{default: '0};
        fwd_data_arr     = '{default: '0};
        highest_idx      = '{default: '0};
        selected_idx     = '0;
        store_covers_load=  '0;
        dcache_req_idx   = '0;
        



        //request broadcast and broadcast it 1 cycle later
        //we can execute out of order
        for(int i = 0; i < `LQ_SZ; i++)begin
            if(lq[LQ_IDX'(head+i)].valid && lq[LQ_IDX'(head+i)].data_ready && lq[LQ_IDX'(head+i)].addr_ready) begin
                cdb_req_load = '1;
                lq_out_next.valid = '1;
                lq_out_next.dest_tag = lq[LQ_IDX'(head+i)].dest_tag;
                lq_out_next.data = lq[LQ_IDX'(head+i)].data;
                lq_out_next.rob_index = lq[LQ_IDX'(head+i)].rob_index;
                lq_n[LQ_IDX'(head+i)] = '0;
                break;
            end
        end

        // head move
        for(int i = 0; i < `LQ_SZ; i++) begin
            if(!lq_n[LQ_IDX'(head + i)].valid) begin
                head_next = LQ_IDX'(head + i + 1);
            end else begin
                break;
            end
        end


        //forward and dcache request

        //----------------------------------------------------
        // step1: generate forward mask for each lq entry
        // fwd_mask = stores that are older than load 老and still in SQ
        //----------------------------------------------------
        for(int i = 0; i < `LQ_SZ; i++) begin
            if(lq[i].valid && lq[i].addr_ready && !lq[i].data_ready) begin
                fwd_mask_arr[i] = lq[i].old_sq_valid_mask & sq_valid_in;
            end
        end

        //----------------------------------------------------
        // step2: generate addr match mask for each lq entry
        //----------------------------------------------------
        for(int i = 0; i < `LQ_SZ; i++) begin
        addr_match_mask[i] = '0;
            if(lq[i].valid && lq[i].addr_ready && !lq[i].data_ready) begin
                for(int j = 0; j < `SQ_SZ; j++) begin
                    addr_match_mask[i][j] = fwd_mask_arr[i][j]
                                    && sq_addr_ready_in[j]
                                    && (sq_addr_in[j] == lq[i].addr);
                end
            end
        end

        //----------------------------------------------------
        // step3: if match mask is not empty
        //        find the youngest store that is older than current load
        //----------------------------------------------------

        for (int i = 0; i < `LQ_SZ; i++) begin
            doubled[i]       = '0;
            shifted[i]       = '0;
            fwd_hit_arr[i]   = '0;
            fwd_data_arr[i]  = '0;
            conflict_arr[i]  = '0;

            if (lq[i].valid && lq[i].addr_ready && !lq[i].data_ready && |addr_match_mask[i]) begin
                // doubled match mask
                doubled[i] = {addr_match_mask[i], addr_match_mask[i]};

                // right shift "tail_idx" bit，so tail entry bacome the lowest bit
                shifted[i] = doubled[i] >> lq[i].sq_tail_position;

                //trunc from lowest bit
                shifted_trunc[i] = shifted[i][`SQ_SZ-1:0];

                //the highest 1 will be the youngest older store
                prefix_or[i] = shifted_trunc[i];
                for (int j = `SQ_SZ-2; j >= 0; j--) begin
                    prefix_or[i][j] = prefix_or[i][j+1] | shifted_trunc[i][j];
                end

                // shifted_trunc = 00010010
                // prefix_or =00011111
                // prefix_or >> 1 = 00001111
                //~prefix_or = 11110000
                // prefix_or & ~prefix_or = 00010000
                highest_mask[i] = prefix_or[i] & ~(prefix_or[i] >> 1);

                highest_idx[i] = '0;
                for (int j = 0; j < `SQ_SZ; j++) begin
                    if (highest_mask[i][j])
                        highest_idx[i] = SQ_IDX'(j);
                end


                selected_idx = SQ_IDX'(highest_idx[i] + lq[i].sq_tail_position);
                store_covers_load = (lq[i].funct3[1:0] >= sq_funct3_in[selected_idx][1:0]);

                //check if the youngest older store's data is ready
                if (sq_data_ready_in[selected_idx]) begin
                    if (store_covers_load) begin
                        fwd_hit_arr[i]  = 1'b1;
                        case(lq[i].funct3[1:0])
                            2'b00: begin // lb/lbu
                                case(lq[i].addr[1:0])
                                    2'b00: fwd_data_arr[i] = lq[i].funct3[2] ? 
                                            {24'b0, sq_data_in[selected_idx][7:0]} :
                                            {{24{sq_data_in[selected_idx][7]}},  sq_data_in[selected_idx][7:0]};
                                    2'b01: fwd_data_arr[i] = lq[i].funct3[2] ? 
                                            {24'b0, sq_data_in[selected_idx][15:8]} :
                                            {{24{sq_data_in[selected_idx][15]}}, sq_data_in[selected_idx][15:8]};
                                    2'b10: fwd_data_arr[i] = lq[i].funct3[2] ? 
                                            {24'b0, sq_data_in[selected_idx][23:16]} :
                                            {{24{sq_data_in[selected_idx][23]}}, sq_data_in[selected_idx][23:16]};
                                    2'b11: fwd_data_arr[i] = lq[i].funct3[2] ? 
                                            {24'b0, sq_data_in[selected_idx][31:24]} :
                                            {{24{sq_data_in[selected_idx][31]}}, sq_data_in[selected_idx][31:24]};
                                endcase
                            end
                            2'b01: begin // lh/lhu
                                case(lq[i].addr[1])
                                    1'b0: fwd_data_arr[i] = lq[i].funct3[2] ? 
                                            {16'b0, sq_data_in[selected_idx][15:0]} :
                                            {{16{sq_data_in[selected_idx][15]}}, sq_data_in[selected_idx][15:0]};
                                    1'b1: fwd_data_arr[i] = lq[i].funct3[2] ? 
                                            {16'b0, sq_data_in[selected_idx][31:16]} :
                                            {{16{sq_data_in[selected_idx][31]}}, sq_data_in[selected_idx][31:16]};
                                endcase
                            end
                            2'b10: begin // lw
                                fwd_data_arr[i] = sq_data_in[selected_idx];
                            end
                            default: fwd_data_arr[i] = sq_data_in[selected_idx];
                        endcase
                    end else begin
                        conflict_arr[i] = 1'b1; // mixed-width or partial-width case: stall
                    end
                end else begin
                    conflict_arr[i] = 1'b1; // matching older store not ready
                end

            end
        end


        //----------------------------------------------------
        // step4: update lq_n based on forwarding result
        // forwarding hit  → fill in data
        // forwarding miss → request load from dcache（每拍只发一个）
        //----------------------------------------------------
        for(int i = 0; i < `LQ_SZ; i++) begin
            if(fwd_hit_arr[i]) begin
                lq_n[i].data       = fwd_data_arr[i];
                lq_n[i].data_ready = 1'b1;
            end
        end



        // dcache request, start from head
        for(int i = 0; i < `LQ_SZ; i++) begin
            dcache_req_idx = LQ_IDX'(head + i);

            has_pending_store = 1'b0;
            for(int j = 0; j < `SQ_SZ; j++) begin
                if(fwd_mask_arr[dcache_req_idx][j] && sq_ready_retire_in[j]) begin
                    has_pending_store = 1'b1;
                end
            end

            if(lq[dcache_req_idx].valid 
                && lq[dcache_req_idx].addr_ready 
                && dcache_can_accept_load
                && !lq[dcache_req_idx].data_ready 
                && !lq[dcache_req_idx].issued 
                && !fwd_hit_arr[dcache_req_idx]
                && !conflict_arr[dcache_req_idx]
                && !has_pending_store) begin //only request when no conflict
                    load_packet.valid    = 1'b1;
                    load_packet.addr     = lq[dcache_req_idx].addr;
                    load_packet.lq_index = dcache_req_idx;
                    load_packet.funct3 = lq[dcache_req_idx].funct3;
                    lq_n[dcache_req_idx].issued     = 1'b1;
                    break;
            end
        end

        // dcache return write back
        if(dcache_load_packet.valid &&  lq_n[dcache_load_packet.lq_index].valid && lq_n[dcache_load_packet.lq_index].issued) begin
            lq_n[dcache_load_packet.lq_index].data       = dcache_load_packet.data;
            lq_n[dcache_load_packet.lq_index].data_ready  = 1'b1;
            lq_n[dcache_load_packet.lq_index].issued      = 1'b0;
        end
        //fill in address from execute stage
        if(load_execute_pack.valid) begin
            lq_n[load_execute_pack.lq_index].addr       = load_execute_pack.addr;
            lq_n[load_execute_pack.lq_index].addr_ready = 1;
        end


        //dispatch
        if(mispredicted)begin
            tail_next = BS_lq_tail_in;
            //flush entry
            for(int i = 0; i < `LQ_SZ; i++) begin
                if(tail >= BS_lq_tail_in) begin
                    // no wrap around
                    if(i >= BS_lq_tail_in && i < tail)
                        lq_n[i] = '{default:'0};
                end else begin
                    // wrap around
                    if(i >= BS_lq_tail_in || i < tail)
                        lq_n[i] = '{default:'0};
                end
            end
        end else begin
            //dispatch logic
            for(int i = 0; i < `N; i++) begin
                if(is_load[i])begin
                    lq_n[tail_next].valid = '1;
                    lq_n[tail_next].dest_tag = dest_tag_in[i];
                    lq_n[tail_next].funct3 = inst_in[i].i.funct3;
                    lq_n[tail_next].old_sq_valid_mask = sq_valid_in_mask[i];
                    lq_n[tail_next].sq_tail_position = sq_tail_in[i];
                    lq_n[tail_next].rob_index = rob_index[i];
                    lq_n[tail_next].addr_ready = '0;
                    lq_n[tail_next].data_ready = '0;
                    lq_n[tail_next].issued = '0;
                    lq_index [i] = tail_next;
                    tail_next = tail_next + 1;
                end
                if(is_branch[i])begin
                    BS_lq_tail_out[i] = tail_next;
                end
            end
        end

         //calculate available space
        full_n = mispredicted ? (head_next == tail_next && full) :  
                                full ? (head_next == tail_next) :
                                ((tail_next == head_next) && (tail_next != tail));       
                                
        free_slots = (full_n)? 0 : 
                        (head_next == tail_next) ? `LQ_SZ :
                        (head_next > tail_next) ? LQ_IDX'(head_next - tail_next) : 
                        LQ_IDX'(`LQ_SZ - (tail_next - head_next));


    
        lq_space_available = full_n             ? 0 :
                            (head_next == tail_next) ? 2 : // empty
                            (free_slots >= 2)  ? 2 :
                            (free_slots == 1)  ? 1 : 0;
    end

    always_ff @(posedge clock)begin
        if(reset)begin
            head <= '0;
            tail <= '0;
            lq <= '{default:'0};
            lq_out_r <= '0;
            full <= '0;
        end else begin
            head <= head_next;
            tail <= tail_next;
            lq <= lq_n;
            lq_out_r <= lq_out_next;
            full <= full_n;
        end
    end





endmodule