`include "sys_defs.svh"

module store_queue (
    input logic clock,
    input logic reset,
    //from dispatch stage
    input INST           [`N-1:0]         inst_in               ,
    input logic           [`N-1:0]       is_load                ,
    input logic                 [`N-1:0]      is_store          ,
    input logic      [`N-1:0]           is_branch               ,
    //from rob
    input ROB_IDX               rob_index               [`N-1:0],
    //from execute stage, data and address
    input SQ_PACKET             store_execute_pack              ,
    //from retire stage
    input SQ_PACKET             store_retire_pack       [`N-1:0],
    //mispredict recovery
    input logic                 mispredicted                    ,
    input SQ_IDX                BS_sq_tail_in                   ,
    //from dcache
    input logic                 dcache_can_accept                 ,


    //commit to D cache through PRSB
    output SQ_PACKET            sq_out                          ,
    //take snapshot to branch stack
    output SQ_IDX               BS_sq_tail_out          [`N-1:0],
    //to dispatch stage
    output logic [1:0]          sq_space_available              ,
    //to rs 
    output logic [`SQ_SZ-1:0]   sq_addr_ready_mask              ,
    //to rs & rob & lq
    output  SQ_IDX              sq_index                [`N-1:0],
    output  SQ_IDX              sq_head_out                     ,
    //store to load forwarding
    output ADDR                 sq_addr_out         [`SQ_SZ-1:0],
    output logic                sq_addr_ready_out   [`SQ_SZ-1:0],
    output DATA                 sq_data_out         [`SQ_SZ-1:0],
    output logic                sq_data_ready_out   [`SQ_SZ-1:0],
    output logic [2:0]          sq_funct3_out       [`SQ_SZ-1:0],
    output logic [`SQ_SZ-1:0]   sq_valid_out                    ,
    output logic [`SQ_SZ-1:0]   sq_valid_out_mask       [`N-1:0],
    output SQ_IDX               sq_tail_out             [`N-1:0]
);

    typedef struct packed {
        logic        valid;
        logic        ready_retire;
        ADDR         addr;
        logic        addr_ready;
        DATA         data;
        logic        data_ready;
        ROB_IDX      rob_index;
        logic [2:0]  funct3;
    } SQ_ENTRY;

    SQ_ENTRY sq         [`SQ_SZ-1:0];
    SQ_ENTRY sq_n       [`SQ_SZ-1:0];

    logic   full, full_n;
    SQ_IDX head, head_next;
    SQ_IDX tail, tail_next;
    SQ_CNT free_slots;
    logic [`SQ_SZ-1:0] sq_valid_snapshot;
    logic head_moved;

    assign sq_head_out = head;

    always_comb begin
        sq_n               = sq;
        head_next          = head;
        tail_next          = tail;
        full_n             = full;
        sq_addr_ready_mask = '0;
        sq_out             = '{default:'0};
        sq_index           = '{default: '0};
        sq_addr_out        = '{default: '0};
        sq_data_out        = '{default: '0};
        sq_valid_out_mask  = '{default: '0};
        BS_sq_tail_out     = '{default: '0};
        sq_funct3_out      = '{default:'0};
        sq_tail_out        = '{default:'0};
        sq_valid_out       = '0;
        head_moved         = '0;

        //----------------------------------------------------
        // commit/retire logic
        //----------------------------------------------------
        if (dcache_can_accept) begin
            if (sq[head].valid && sq[head].ready_retire) begin
                sq_out.valid  = 1;
                sq_out.addr   = sq[head].addr;
                sq_out.data   = sq[head].data;
                sq_out.funct3 = sq[head].funct3;
                sq_n[head]    = '0;
                head_next     = head_next + 1;
                head_moved    = 1'b1;
            end
        end

        //----------------------------------------------------
        // set ready_retire (two-cycle path, no combinational loop)
        //----------------------------------------------------
        for (int i = 0; i < `N; i++) begin
            if (store_retire_pack[i].valid) begin
                if (sq[store_retire_pack[i].sq_index].valid
                 && sq[store_retire_pack[i].sq_index].addr_ready
                 && sq[store_retire_pack[i].sq_index].data_ready) begin
                    sq_n[store_retire_pack[i].sq_index].ready_retire = 1;
                end
            end
        end

        //----------------------------------------------------
        // forwarding outputs
        //----------------------------------------------------
        for (int i = 0; i < `SQ_SZ; i++) begin
            sq_addr_out[i]        = sq[i].addr;
            sq_data_out[i]        = sq[i].data;
            sq_data_ready_out[i]  = sq[i].data_ready;
            sq_addr_ready_out[i]  = sq[i].addr_ready;
            sq_addr_ready_mask[i] = sq[i].addr_ready;
            sq_valid_snapshot[i]  = sq[i].valid;
            sq_valid_out[i]       = sq[i].valid;
            sq_funct3_out[i]      = sq[i].funct3;
        end

        //----------------------------------------------------
        // execute stage writeback
        //----------------------------------------------------
        if (store_execute_pack.valid && sq[store_execute_pack.sq_index].valid) begin
            sq_n[store_execute_pack.sq_index].addr       = store_execute_pack.addr;
            sq_n[store_execute_pack.sq_index].addr_ready = 1;
            sq_n[store_execute_pack.sq_index].data_ready = 1;
            sq_n[store_execute_pack.sq_index].data       = store_execute_pack.data;
        end

        //----------------------------------------------------
        // mispredict recovery / dispatch
        //----------------------------------------------------
        if (mispredicted) begin
            tail_next = BS_sq_tail_in;
            for (int i = 0; i < `SQ_SZ; i++) begin
                if (full && tail == BS_sq_tail_in) begin
                    sq_n[i] = '{default:'0};
                end else if (BS_sq_tail_in <= tail) begin
                    if (i >= BS_sq_tail_in && i < tail)
                        sq_n[i] = '{default:'0};
                end else begin
                    if (i >= BS_sq_tail_in || i < tail)
                        sq_n[i] = '{default:'0};
                end
            end
        end else begin
            for (int i = 0; i < `N; i++) begin
                if (is_store[i]) begin
                    sq_n[tail_next].valid     = 1;
                    sq_n[tail_next].funct3    = inst_in[i].s.funct3;
                    sq_n[tail_next].rob_index = rob_index[i];
                    sq_valid_snapshot[tail_next] = 1;
                    sq_index[i] = tail_next;
                    tail_next   = tail_next + 1;
                end
                if (is_branch[i]) begin
                    BS_sq_tail_out[i] = tail_next;
                end
                if (is_load[i]) begin
                    sq_tail_out[i]      = tail_next;
                    sq_valid_out_mask[i]= sq_valid_snapshot;
                end
            end
        end

        //----------------------------------------------------
        // full / available space
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

        free_slots = full_n ? 0 :
                     (head_next == tail_next) ? `SQ_SZ :
                     (head_next > tail_next)  ? SQ_IDX'(head_next - tail_next) :
                                                SQ_IDX'(`SQ_SZ - (tail_next - head_next));

        sq_space_available = (free_slots >= 2) ? 2'd2 :
                             (free_slots == 1)  ? 2'd1 : 2'd0;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            head <= 0;
            tail <= 0;
            sq   <= '{default:'0};
            full <= '0;
        end else begin
            head <= head_next;
            tail <= tail_next;
            sq   <= sq_n;
            full <= full_n;
        end
    end

endmodule