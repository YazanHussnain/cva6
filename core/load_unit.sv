// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba    <zarubaf@iis.ee.ethz.ch>, ETH Zurich
//         Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 15.08.2018
// Description: Load Unit, takes care of all load requests
//
// Contributor: Cesar Fuguet <cesar.fuguettortolero@cea.fr>, CEA List
// Date: August 29, 2023
// Modification: add support for multiple outstanding load operations
//               to the data cache

module load_unit import ariane_pkg::*; #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic                     clk_i,    // Clock
    input  logic                     rst_ni,   // Asynchronous reset active low
    input  logic                     flush_i,
    // load unit input port
    input  logic                     valid_i,
    input  lsu_ctrl_t                lsu_ctrl_i,
    output logic                     pop_ld_o,
    // load unit output port
    output logic                     valid_o,
    output logic [TRANS_ID_BITS-1:0] trans_id_o,
    output riscv::xlen_t             result_o,
    output exception_t               ex_o,
    // MMU -> Address Translation
    output logic                     translation_req_o,   // request address translation
    output logic [riscv::VLEN-1:0]   vaddr_o,             // virtual address out
    input  logic [riscv::PLEN-1:0]   paddr_i,             // physical address in
    input  exception_t               ex_i,                // exception which may has happened earlier. for example: mis-aligned exception
    input  logic                     dtlb_hit_i,          // hit on the dtlb, send in the same cycle as the request
    input  logic [riscv::PPNW-1:0]   dtlb_ppn_i,          // ppn on the dtlb, send in the same cycle as the request
    // address checker
    output logic [11:0]              page_offset_o,
    input  logic                     page_offset_matches_i,
    input  logic                     store_buffer_empty_i, // the entire store-buffer is empty
    input  logic [TRANS_ID_BITS-1:0] commit_tran_id_i,
    // D$ interface
    input dcache_req_o_t             req_port_i,
    output dcache_req_i_t            req_port_o,
    input  logic                     dcache_wbuffer_not_ni_i
);
    enum logic [3:0] { IDLE, WAIT_GNT, SEND_TAG, WAIT_PAGE_OFFSET,
                       ABORT_TRANSACTION, ABORT_TRANSACTION_NI, WAIT_TRANSLATION, WAIT_FLUSH,
                       WAIT_WB_EMPTY
                     } state_d, state_q;

    // in order to decouple the response interface from the request interface,
    // we need a a buffer which can hold all inflight memory load requests
    typedef struct packed {
        logic [TRANS_ID_BITS-1:0]           trans_id;       // scoreboard identifier
        logic [riscv::XLEN_ALIGN_BYTES-1:0] address_offset; // least significant bits of the address
        fu_op                               operation;      // type of load
    } ldbuf_t;


    // to support a throughput of one load per cycle, if the number of entries
    // of the load buffer is 1, implement a fall-through mode. This however
    // adds a combinational path between the request and response interfaces
    // towards the cache.
    localparam logic LDBUF_FALLTHROUGH = (CVA6Cfg.NrLoadBufEntries == 1);
    localparam int unsigned REQ_ID_BITS = CVA6Cfg.NrLoadBufEntries > 1 ?
                                          $clog2(CVA6Cfg.NrLoadBufEntries) : 1;

    typedef logic [REQ_ID_BITS-1:0] ldbuf_id_t;

    logic   [CVA6Cfg.NrLoadBufEntries-1:0] ldbuf_valid_q, ldbuf_valid_d;
    logic   [CVA6Cfg.NrLoadBufEntries-1:0] ldbuf_flushed_q, ldbuf_flushed_d;
    ldbuf_t [CVA6Cfg.NrLoadBufEntries-1:0] ldbuf_q;
    logic                                  ldbuf_empty, ldbuf_full;
    ldbuf_id_t                             ldbuf_free_index;
    logic                                  ldbuf_w;
    ldbuf_t                                ldbuf_wdata;
    ldbuf_id_t                             ldbuf_windex;
    logic                                  ldbuf_r;
    ldbuf_t                                ldbuf_rdata;
    ldbuf_id_t                             ldbuf_rindex;
    ldbuf_id_t                             ldbuf_last_id_q;

    assign ldbuf_full = &ldbuf_valid_q;

    //
    //  buffer of outstanding loads

    //  write in the first available slot
    generate
        if (CVA6Cfg.NrLoadBufEntries > 1) begin : ldbuf_free_index_multi_gen
            lzc #(
                .WIDTH   (CVA6Cfg.NrLoadBufEntries),
                .MODE    (1'b0) // Count leading zeros
            ) lzc_windex_i (
                .in_i    (~ldbuf_valid_q),
                .cnt_o   (ldbuf_free_index),
                .empty_o (ldbuf_empty)
            );
        end else begin : ldbuf_free_index_single_gen
            assign ldbuf_free_index = 1'b0;
        end
    endgenerate

    assign ldbuf_windex = (LDBUF_FALLTHROUGH && ldbuf_r) ? ldbuf_rindex : ldbuf_free_index;

    always_comb
    begin : ldbuf_comb
        ldbuf_flushed_d = ldbuf_flushed_q;
        ldbuf_valid_d   = ldbuf_valid_q;

        //  In case of flush, raise the flushed flag in all slots.
        if (flush_i) begin
            ldbuf_flushed_d = '1;
        end
        //  Free read entry (in the case of fall-through mode, free the entry
        //  only if there is no pending load)
        if (ldbuf_r && (!LDBUF_FALLTHROUGH || !ldbuf_w)) begin
            ldbuf_valid_d[ldbuf_rindex] = 1'b0;
        end
        //  Track a new outstanding operation in the load buffer
        if (ldbuf_w) begin
            ldbuf_flushed_d[ldbuf_windex] = 1'b0;
            ldbuf_valid_d[ldbuf_windex] = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni)
    begin : ldbuf_ff
        if (!rst_ni) begin
            ldbuf_flushed_q <= '0;
            ldbuf_valid_q   <= '0;
            ldbuf_last_id_q <= '0;
            ldbuf_q         <= '0;
        end else begin
            ldbuf_flushed_q <= ldbuf_flushed_d;
            ldbuf_valid_q   <= ldbuf_valid_d;
            if (ldbuf_w) begin
                ldbuf_last_id_q       <= ldbuf_windex;
                ldbuf_q[ldbuf_windex] <= ldbuf_wdata;
            end
        end
    end

    // page offset is defined as the lower 12 bits, feed through for address checker
    assign page_offset_o = lsu_ctrl_i.vaddr[11:0];
    // feed-through the virtual address for VA translation
    assign vaddr_o = lsu_ctrl_i.vaddr;
    // this is a read-only interface so set the write enable to 0
    assign req_port_o.data_we = 1'b0;
    assign req_port_o.data_wdata = '0;
    // compose the load buffer write data, control is handled in the FSM
    assign ldbuf_wdata = {lsu_ctrl_i.trans_id, lsu_ctrl_i.vaddr[riscv::XLEN_ALIGN_BYTES-1:0], lsu_ctrl_i.operation};
    // output address
    // we can now output the lower 12 bit as the index to the cache
    assign req_port_o.address_index = lsu_ctrl_i.vaddr[ariane_pkg::DCACHE_INDEX_WIDTH-1:0];
    // translation from last cycle, again: control is handled in the FSM
    assign req_port_o.address_tag   = paddr_i[ariane_pkg::DCACHE_TAG_WIDTH     +
                                              ariane_pkg::DCACHE_INDEX_WIDTH-1 :
                                              ariane_pkg::DCACHE_INDEX_WIDTH];
    // request id = index of the load buffer's entry
    assign req_port_o.data_id = ldbuf_windex;
    // directly forward exception fields (valid bit is set below)
    assign ex_o.cause = ex_i.cause;
    assign ex_o.tval  = ex_i.tval;

    // Check that NI operations follow the necessary conditions
    logic paddr_ni;
    logic not_commit_time;
    logic inflight_stores;
    logic stall_ni;
    assign paddr_ni = is_inside_nonidempotent_regions(ArianeCfg, {dtlb_ppn_i,{riscv::XLEN-riscv::PPNW{1'b0}}});
    assign not_commit_time = commit_tran_id_i != lsu_ctrl_i.trans_id;
    assign inflight_stores = (!dcache_wbuffer_not_ni_i || !store_buffer_empty_i);
    assign stall_ni = (inflight_stores || not_commit_time) && paddr_ni;

    // ---------------
    // Load Control
    // ---------------
    always_comb begin : load_control
        automatic logic accept_req;

        // default assignments
        state_d              = state_q;
        translation_req_o    = 1'b0;
        req_port_o.data_req  = 1'b0;
        // tag control
        req_port_o.kill_req  = 1'b0;
        req_port_o.tag_valid = 1'b0;
        req_port_o.data_be   = lsu_ctrl_i.be;
        req_port_o.data_size = extract_transfer_size(lsu_ctrl_i.operation);
        pop_ld_o             = 1'b0;

        // In IDLE and SEND_TAG states, this unit can accept a new load request
        // when the load buffer is not full or if there is a response and the
        // load buffer is in fall-through mode
        accept_req = (valid_i && (!ldbuf_full || (LDBUF_FALLTHROUGH && ldbuf_r)));

        case (state_q)
            IDLE: begin
                if (accept_req) begin
                    // start the translation process even though we do not know if the addresses match
                    // this should ease timing
                    translation_req_o = 1'b1;
                    // check if the page offset matches with a store, if it does then stall and wait
                    if (!page_offset_matches_i) begin
                        // make a load request to memory
                        req_port_o.data_req = 1'b1;
                        // we got no data grant so wait for the grant before sending the tag
                        if (!req_port_i.data_gnt) begin
                            state_d = WAIT_GNT;
                        end else begin
                            if (dtlb_hit_i && !stall_ni) begin
                                // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                                state_d = SEND_TAG;
                                pop_ld_o = 1'b1;
                            // translation valid but this is to NC and the WB is not yet empty.
                            end else if (dtlb_hit_i && stall_ni) begin
                                state_d = ABORT_TRANSACTION_NI;
                            end else begin // TLB miss
                                state_d = ABORT_TRANSACTION;
                            end
                        end
                    end else begin
                        // wait for the store buffer to train and the page offset to not match anymore
                        state_d = WAIT_PAGE_OFFSET;
                    end
                end
            end

            // wait here for the page offset to not match anymore
            WAIT_PAGE_OFFSET: begin
                // we make a new request as soon as the page offset does not match anymore
                if (!page_offset_matches_i) begin
                    state_d = WAIT_GNT;
                end
            end

            // abort the previous request - free the D$ arbiter
            // we are here because of a TLB miss, we need to abort the current request and give way for the
            // PTW walker to satisfy the TLB miss
            ABORT_TRANSACTION, ABORT_TRANSACTION_NI: begin
                req_port_o.kill_req  = 1'b1;
                req_port_o.tag_valid = 1'b1;
                // either re-do the request or wait until the WB is empty (depending on where we came from).
                state_d = (state_q == ABORT_TRANSACTION_NI) ? WAIT_WB_EMPTY :  WAIT_TRANSLATION;
            end

            // Wait until the write-back buffer is empty in the data cache.
            WAIT_WB_EMPTY: begin
                // the write buffer is empty, so lets go and re-do the translation.
                if (dcache_wbuffer_not_ni_i) state_d = WAIT_TRANSLATION;
            end

            WAIT_TRANSLATION: begin
                translation_req_o = 1'b1;
                // we've got a hit and we can continue with the request process
                if (dtlb_hit_i)
                    state_d = WAIT_GNT;

                // we got an exception
                if (ex_i.valid) begin
                    // the next state will be the idle state
                    state_d = IDLE;
                    // pop load - but only if we are not getting an rvalid in here - otherwise we will over-write an incoming transaction
                    pop_ld_o = ~req_port_i.data_rvalid;
                end
            end

            WAIT_GNT: begin
                // keep the translation request up
                translation_req_o = 1'b1;
                // keep the request up
                req_port_o.data_req = 1'b1;
                // we finally got a data grant
                if (req_port_i.data_gnt) begin
                    // so we send the tag in the next cycle
                    if (dtlb_hit_i && !stall_ni) begin
                        state_d = SEND_TAG;
                        pop_ld_o = 1'b1;
                    // translation valid but this is to NC and the WB is not yet empty.
                    end else if (dtlb_hit_i && stall_ni) begin
                        state_d = ABORT_TRANSACTION_NI;
                    end else begin
                    // should we not have hit on the TLB abort this transaction an retry later
                        state_d = ABORT_TRANSACTION;
                    end
                end
                // otherwise we keep waiting on our grant
            end
            // we know for sure that the tag we want to send is valid
            SEND_TAG: begin
                req_port_o.tag_valid = 1'b1;
                state_d = IDLE;

                if (accept_req) begin
                    // start the translation process even though we do not know if the addresses match
                    // this should ease timing
                    translation_req_o = 1'b1;
                    // check if the page offset matches with a store, if it does stall and wait
                    if (!page_offset_matches_i) begin
                        // make a load request to memory
                        req_port_o.data_req = 1'b1;
                        // we got no data grant so wait for the grant before sending the tag
                        if (!req_port_i.data_gnt) begin
                            state_d = WAIT_GNT;
                        end else begin
                            // we got a grant so we can send the tag in the next cycle
                            if (dtlb_hit_i && !stall_ni) begin
                                // we got a grant and a hit on the DTLB so we can send the tag in the next cycle
                                state_d = SEND_TAG;
                                pop_ld_o = 1'b1;
                            // translation valid but this is to NC and the WB is not yet empty.
                            end else if (dtlb_hit_i && stall_ni) begin
                                state_d = ABORT_TRANSACTION_NI;
                            end else begin
                                state_d = ABORT_TRANSACTION;// we missed on the TLB -> wait for the translation
                            end
                        end
                    end else begin
                        // wait for the store buffer to train and the page offset to not match anymore
                        state_d = WAIT_PAGE_OFFSET;
                    end
                end
                // ----------
                // Exception
                // ----------
                // if we got an exception we need to kill the request immediately
                if (ex_i.valid) begin
                    req_port_o.kill_req = 1'b1;
                end
            end

            WAIT_FLUSH: begin
                // the D$ arbiter will take care of presenting this to the memory only in case we
                // have an outstanding request
                req_port_o.kill_req  = 1'b1;
                req_port_o.tag_valid = 1'b1;
                // we've killed the current request so we can go back to idle
                state_d = IDLE;
            end

            default: state_d = IDLE;
        endcase

        // if we just flushed and the queue is not empty or we are getting an rvalid this cycle wait in a extra stage
        if (flush_i) begin
            state_d = WAIT_FLUSH;
        end
    end

    // track the load data for later usage
    assign ldbuf_w = req_port_o.data_req & req_port_i.data_gnt;

    // ---------------
    // Retire Load
    // ---------------
    assign ldbuf_rindex = (CVA6Cfg.NrLoadBufEntries > 1) ? ldbuf_id_t'(req_port_i.data_rid) : 1'b0,
           ldbuf_rdata  = ldbuf_q[ldbuf_rindex];

    // decoupled rvalid process
    always_comb begin : rvalid_output
        //  read the pending load buffer
        ldbuf_r    = req_port_i.data_rvalid;
        trans_id_o = ldbuf_q[ldbuf_rindex].trans_id;
        valid_o    = 1'b0;
        ex_o.valid = 1'b0;

        // we got an rvalid and it's corresponding request was not flushed
        if (req_port_i.data_rvalid && !ldbuf_flushed_q[ldbuf_rindex]) begin
            // if the response corresponds to the last request, check that we are not killing it
            if((ldbuf_last_id_q != ldbuf_rindex) || !req_port_o.kill_req)
                valid_o = 1'b1;
            // the output is also valid if we got an exception. An exception arrives one cycle after
            // dtlb_hit_i is asserted, i.e. when we are in SEND_TAG. Otherwise, the exception
            // corresponds to the next request that is already being translated (see below).
            if (ex_i.valid && (state_q == SEND_TAG)) begin
                valid_o    = 1'b1;
                ex_o.valid = 1'b1;
            end
        end

        // an exception occurred during translation
        // exceptions can retire out-of-order -> but we need to give priority to non-excepting load and stores
        // so we simply check if we got an rvalid if so we prioritize it by not retiring the exception - we simply go for another
        // round in the load FSM
        if ((state_q == WAIT_TRANSLATION) && !req_port_i.data_rvalid && ex_i.valid && valid_i) begin
            trans_id_o = lsu_ctrl_i.trans_id;
            valid_o = 1'b1;
            ex_o.valid = 1'b1;
        end
    end


    // latch physical address for the tag cycle (one cycle after applying the index)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q <= IDLE;
        end else begin
            state_q <= state_d;
        end
    end

    // ---------------
    // Sign Extend
    // ---------------
    riscv::xlen_t shifted_data;

    // realign as needed
    assign shifted_data = req_port_i.data_rdata >> {ldbuf_rdata.address_offset, 3'b000};

/*  // result mux (leaner code, but more logic stages.
    // can be used instead of the code below (in between //result mux fast) if timing is not so critical)
    always_comb begin
        unique case (ldbuf_rdata.operation)
            LWU:        result_o = shifted_data[31:0];
            LHU:        result_o = shifted_data[15:0];
            LBU:        result_o = shifted_data[7:0];
            LW:         result_o = 64'(signed'(shifted_data[31:0]));
            LH:         result_o = 64'(signed'(shifted_data[15:0]));
            LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
            default:    result_o = shifted_data;
        endcase
    end  */

    // result mux fast
    logic [(riscv::XLEN/8)-1:0]         rdata_sign_bits;
    logic [riscv::XLEN_ALIGN_BYTES-1:0] rdata_offset;
    logic                               rdata_sign_bit, rdata_is_signed, rdata_is_fp_signed;


    // prepare these signals for faster selection in the next cycle
    assign rdata_is_signed    =   ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::LH,  ariane_pkg::LB};
    assign rdata_is_fp_signed =   ldbuf_rdata.operation inside {ariane_pkg::FLW, ariane_pkg::FLH, ariane_pkg::FLB};
    assign rdata_offset       = ((ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::FLW}) & riscv::IS_XLEN64) ? ldbuf_rdata.address_offset + 3 :
                                ( ldbuf_rdata.operation inside {ariane_pkg::LH,  ariane_pkg::FLH})                     ? ldbuf_rdata.address_offset + 1 :
                                                                                                                         ldbuf_rdata.address_offset;

    for (genvar i = 0; i < (riscv::XLEN/8); i++) begin : gen_sign_bits
        assign rdata_sign_bits[i] = req_port_i.data_rdata[(i+1)*8-1];
    end


    // select correct sign bit in parallel to result shifter above
    // pull to 0 if unsigned
    assign rdata_sign_bit = rdata_is_signed & rdata_sign_bits[rdata_offset] | rdata_is_fp_signed;

    // result mux
    always_comb begin
        unique case (ldbuf_rdata.operation)
            ariane_pkg::LW, ariane_pkg::LWU, ariane_pkg::FLW: result_o = {{riscv::XLEN-32{rdata_sign_bit}}, shifted_data[31:0]};
            ariane_pkg::LH, ariane_pkg::LHU, ariane_pkg::FLH: result_o = {{riscv::XLEN-32+16{rdata_sign_bit}}, shifted_data[15:0]};
            ariane_pkg::LB, ariane_pkg::LBU, ariane_pkg::FLB: result_o = {{riscv::XLEN-32+24{rdata_sign_bit}}, shifted_data[7:0]};
            default:                                          result_o = shifted_data[riscv::XLEN-1:0];
        endcase
    end
    // end result mux fast

    ///////////////////////////////////////////////////////
    // assertions
    ///////////////////////////////////////////////////////

//pragma translate_off
`ifndef VERILATOR
    initial assert (ariane_pkg::DCACHE_TID_WIDTH >= REQ_ID_BITS) else
        $fatal(1, "CVA6ConfigDcacheIdWidth parameter is not wide enough to encode pending loads");
    // check invalid offsets, but only issue a warning as these conditions actually trigger a load address misaligned exception
    addr_offset0: assert property (@(posedge clk_i) disable iff (~rst_ni)
        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LW, ariane_pkg::LWU}) |-> ldbuf_wdata.address_offset < 5) else
          $fatal(1, "invalid address offset used with {LW, LWU}");
    addr_offset1: assert property (@(posedge clk_i) disable iff (~rst_ni)
        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LH, ariane_pkg::LHU}) |-> ldbuf_wdata.address_offset < 7) else
          $fatal(1, "invalid address offset used with {LH, LHU}");
    addr_offset2: assert property (@(posedge clk_i) disable iff (~rst_ni)
        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LB, ariane_pkg::LBU}) |-> ldbuf_wdata.address_offset < 8) else
          $fatal(1, "invalid address offset used with {LB, LBU}");
`endif
//pragma translate_on

endmodule
