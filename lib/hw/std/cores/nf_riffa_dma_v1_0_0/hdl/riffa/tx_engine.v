//----------------------------------------------------------------------------
// This software is Copyright © 2015 The Regents of the University of 
// California. All Rights Reserved.
//
// Permission to copy, modify, and distribute this software and its 
// documentation for educational, research and non-profit purposes, without 
// fee, and without a written agreement is hereby granted, provided that the 
// above copyright notice, this paragraph and the following three paragraphs 
// appear in all copies.
//
// Permission to make commercial use of this software may be obtained by 
// contacting:
// Technology Transfer Office
// 9500 Gilman Drive, Mail Code 0910
// University of California
// La Jolla, CA 92093-0910
// (858) 534-5815
// invent@ucsd.edu
// 
// This software program and documentation are copyrighted by The Regents of 
// the University of California. The software program and documentation are 
// supplied "as is", without any accompanying services from The Regents. The 
// Regents does not warrant that the operation of the program will be 
// uninterrupted or error-free. The end-user understands that the program was 
// developed for research purposes and is advised not to rely exclusively on 
// the program for any reason.
// 
// IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO
// ANY PARTY FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR
// CONSEQUENTIAL DAMAGES, INCLUDING LOST PROFITS, ARISING
// OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION,
// EVEN IF THE UNIVERSITY OF CALIFORNIA HAS BEEN ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE. THE UNIVERSITY OF
// CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES,
// INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.
// THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, 
// AND THE UNIVERSITY OF CALIFORNIA HAS NO OBLIGATIONS TO
// PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR
// MODIFICATIONS.
//----------------------------------------------------------------------------
//----------------------------------------------------------------------------
// Filename: tx_engine.v
// Version:             1.0
// Verilog Standard:    Verilog-2001
// Description: The tx_engine module takes a formatted header, number of alignment
// blanks and a payloa and concatenates all three (in that order) to form a
// packet. These packets must meet max-request, max-payload, and payload
// termination requirements (see Read Completion Boundary). The tx_engine does
// not check these requirements during operation, but may do so during simulation.
// This Engine is capable of operating at "line rate".
// Author:              Dustin Richmond (@darichmond)
//-----------------------------------------------------------------------------
`timescale 1ns/1ns
`include "trellis.vh" // Defines the user-facing signal widths.
module tx_engine
    #(parameter C_DATA_WIDTH = 128,
      parameter C_DEPTH_PACKETS = 10,
      parameter C_PIPELINE_INPUT = 1,
      parameter C_PIPELINE_OUTPUT = 0,
      parameter C_FORMATTER_DELAY = 1,
      parameter C_MAX_HDR_WIDTH  = 128,
      parameter C_MAX_PAYLOAD_DWORDS = 64,
      parameter C_VENDOR = "ALTERA"
      )
    (
     // Interface: Clocks
     input                                CLK,

     // Interface: Reset
     input                                RST_IN,

     // Interface: TX HDR
     input                                TX_HDR_VALID,
     input [C_MAX_HDR_WIDTH-1:0]          TX_HDR,
     input [`SIG_LEN_W-1:0]               TX_HDR_PAYLOAD_LEN,
     input [`SIG_NONPAY_W-1:0]            TX_HDR_NONPAY_LEN,
     input [`SIG_PACKETLEN_W-1:0]         TX_HDR_PACKET_LEN,
     input                                TX_HDR_NOPAYLOAD,
     output                               TX_HDR_READY,

     // Interface: TX_DATA
     input                                TX_DATA_VALID,
     input [C_DATA_WIDTH-1:0]             TX_DATA,
     input                                TX_DATA_START_FLAG,
     input [clog2s(C_DATA_WIDTH/32)-1:0]  TX_DATA_START_OFFSET,
     input                                TX_DATA_END_FLAG,
     input [clog2s(C_DATA_WIDTH/32)-1:0]  TX_DATA_END_OFFSET,
     output                               TX_DATA_READY,

     // Interface: TX_PKT
     input                                TX_PKT_READY,
     output [C_DATA_WIDTH-1:0]            TX_PKT,
     output                               TX_PKT_START_FLAG,
     output [clog2s(C_DATA_WIDTH/32)-1:0] TX_PKT_START_OFFSET,
     output                               TX_PKT_END_FLAG,
     output [clog2s(C_DATA_WIDTH/32)-1:0] TX_PKT_END_OFFSET,
     output                               TX_PKT_VALID
     );
    localparam C_PIPELINE_HDR_FIFO_INPUT = C_PIPELINE_INPUT;
    localparam C_PIPELINE_HDR_FIFO_OUTPUT = C_PIPELINE_OUTPUT;
    localparam C_PIPELINE_HDR_INPUT = C_PIPELINE_INPUT;
    localparam C_ACTUAL_HDR_FIFO_DEPTH = clog2s(C_DEPTH_PACKETS);
    localparam C_USE_COMPUTE_REG = 1;
    localparam C_USE_READY_REG = 1;
    localparam C_USE_FWFT_HDR_FIFO = 1;
    localparam C_DATA_FIFO_DEPTH = C_ACTUAL_HDR_FIFO_DEPTH + C_FORMATTER_DELAY + 
                                   C_PIPELINE_HDR_FIFO_INPUT + C_PIPELINE_HDR_FIFO_OUTPUT + C_USE_FWFT_HDR_FIFO + // Header Fifo
                                   C_PIPELINE_HDR_INPUT + C_USE_COMPUTE_REG + C_USE_READY_REG + C_PIPELINE_OUTPUT; // Aligner

    wire                                  wTxHdrReady;
    wire                                  wTxHdrValid;
    wire [C_MAX_HDR_WIDTH-1:0]            wTxHdr;
    wire [`SIG_NONPAY_W-1:0]              wTxHdrNonpayLen;
    wire [`SIG_PACKETLEN_W-1:0]           wTxHdrPacketLen;
    wire [`SIG_LEN_W-1:0]                 wTxHdrPayloadLen; 
    wire                                  wTxHdrNoPayload;

    wire                                  wTxDataReady;
    wire [C_DATA_WIDTH-1:0]               wTxData;
    wire [clog2s(C_DATA_WIDTH/32)-1:0]    wTxDataEndOffset;
    wire                                  wTxDataStartFlag;
    wire [(C_DATA_WIDTH/32)-1:0]          wTxDataEndFlags;
    wire [(C_DATA_WIDTH/32)-1:0]          wTxDataWordValid;
    wire [(C_DATA_WIDTH/32)-1:0]          wTxDataWordReady;

    tx_data_pipeline
        #(
          .C_MAX_PAYLOAD                (C_MAX_PAYLOAD_DWORDS*32),
          .C_DEPTH_PACKETS              (C_DATA_FIFO_DEPTH),
          /*AUTOINSTPARAM*/
          // Parameters
          .C_DATA_WIDTH                 (C_DATA_WIDTH),
          .C_PIPELINE_INPUT             (C_PIPELINE_INPUT),
          .C_PIPELINE_OUTPUT            (C_PIPELINE_OUTPUT),
          .C_VENDOR                     (C_VENDOR))
    tx_data_pipeline_inst
        (
         // Outputs
         .RD_TX_DATA                  (wTxData[C_DATA_WIDTH-1:0]),
         .RD_TX_DATA_WORD_VALID       (wTxDataWordValid[(C_DATA_WIDTH/32)-1:0]),
         .RD_TX_DATA_START_FLAG       (wTxDataStartFlag),
         .RD_TX_DATA_END_FLAGS        (wTxDataEndFlags[(C_DATA_WIDTH/32)-1:0]),
         .WR_TX_DATA_READY            (TX_DATA_READY),
         // Inputs
         .RD_TX_DATA_WORD_READY       (wTxDataWordReady[(C_DATA_WIDTH/32)-1:0]),
         .WR_TX_DATA                  (TX_DATA),
         .WR_TX_DATA_VALID            (TX_DATA_VALID),
         .WR_TX_DATA_START_FLAG       (TX_DATA_START_FLAG),
         .WR_TX_DATA_START_OFFSET     (TX_DATA_START_OFFSET[clog2s(C_DATA_WIDTH/32)-1:0]),
         .WR_TX_DATA_END_FLAG         (TX_DATA_END_FLAG),
         .WR_TX_DATA_END_OFFSET       (TX_DATA_END_OFFSET[clog2s(C_DATA_WIDTH/32)-1:0]),
         /*AUTOINST*/
         // Inputs
         .CLK                           (CLK),
         .RST_IN                        (RST_IN));

    // TX Header Fifo
    tx_hdr_fifo
        #(
          .C_PIPELINE_OUTPUT            (C_PIPELINE_HDR_FIFO_OUTPUT),
          .C_PIPELINE_INPUT             (C_PIPELINE_HDR_FIFO_INPUT),
          /*AUTOINSTPARAM*/
          // Parameters
          .C_DEPTH_PACKETS              (C_ACTUAL_HDR_FIFO_DEPTH),
          .C_MAX_HDR_WIDTH              (C_MAX_HDR_WIDTH),
          .C_VENDOR                     (C_VENDOR))
    txhf_inst
        (
         // Outputs
         .WR_TX_HDR_READY               (TX_HDR_READY),
         .RD_TX_HDR                     (wTxHdr[C_MAX_HDR_WIDTH-1:0]),
         .RD_TX_HDR_VALID               (wTxHdrValid),
         .RD_TX_HDR_NOPAYLOAD           (wTxHdrNoPayload),
         .RD_TX_HDR_PAYLOAD_LEN         (wTxHdrPayloadLen[`SIG_LEN_W-1:0]),
         .RD_TX_HDR_NONPAY_LEN          (wTxHdrNonpayLen[`SIG_NONPAY_W-1:0]),
         .RD_TX_HDR_PACKET_LEN          (wTxHdrPacketLen[`SIG_PACKETLEN_W-1:0]),
         // Inputs
         .WR_TX_HDR                     (TX_HDR[C_MAX_HDR_WIDTH-1:0]),
         .WR_TX_HDR_VALID               (TX_HDR_VALID),
         .WR_TX_HDR_NOPAYLOAD           (TX_HDR_NOPAYLOAD),
         .WR_TX_HDR_PAYLOAD_LEN         (TX_HDR_PAYLOAD_LEN[`SIG_LEN_W-1:0]),
         .WR_TX_HDR_NONPAY_LEN          (TX_HDR_NONPAY_LEN[`SIG_NONPAY_W-1:0]),
         .WR_TX_HDR_PACKET_LEN          (TX_HDR_PACKET_LEN[`SIG_PACKETLEN_W-1:0]),
         .RD_TX_HDR_READY               (wTxHdrReady),
         /*AUTOINST*/
         // Outputs
         // Inputs
         .CLK                           (CLK),
         .RST_IN                        (RST_IN));

    // TX Header Fifo
    tx_alignment_pipeline
        #(
          // Parameters
          .C_PIPELINE_OUTPUT            (1),
          .C_PIPELINE_DATA_INPUT        (1),
          .C_PIPELINE_HDR_INPUT         (C_PIPELINE_HDR_INPUT),
          .C_DATA_WIDTH                 (C_DATA_WIDTH),
          // Parameters
          /*AUTOINSTPARAM*/
          // Parameters
          .C_USE_COMPUTE_REG            (C_USE_COMPUTE_REG),
          .C_USE_READY_REG              (C_USE_READY_REG),
          .C_VENDOR                     (C_VENDOR))
    tx_alignment_inst
        (
         // Outputs
         .TX_DATA_WORD_READY            (wTxDataWordReady[(C_DATA_WIDTH/32)-1:0]),
         .TX_HDR_READY                  (wTxHdrReady),
         .TX_PKT                        (TX_PKT[C_DATA_WIDTH-1:0]),
         .TX_PKT_VALID                  (TX_PKT_VALID),
         .TX_PKT_START_FLAG             (TX_PKT_START_FLAG),
         .TX_PKT_START_OFFSET           (TX_PKT_START_OFFSET[clog2s(C_DATA_WIDTH/32)-1:0]),
         .TX_PKT_END_FLAG               (TX_PKT_END_FLAG),
         .TX_PKT_END_OFFSET             (TX_PKT_END_OFFSET[clog2s(C_DATA_WIDTH/32)-1:0]),
         // Inputs
         .TX_DATA_START_FLAG            (wTxDataStartFlag),
         .TX_DATA_END_FLAGS             (wTxDataEndFlags),
         .TX_DATA_WORD_VALID            (wTxDataWordValid[(C_DATA_WIDTH/32)-1:0]),
         .TX_DATA                       (wTxData[C_DATA_WIDTH-1:0]),
         .TX_HDR                        (wTxHdr[C_MAX_HDR_WIDTH-1:0]),
         .TX_HDR_VALID                  (wTxHdrValid),
         .TX_HDR_NOPAYLOAD              (wTxHdrNoPayload),
         .TX_HDR_PAYLOAD_LEN            (wTxHdrPayloadLen[`SIG_LEN_W-1:0]),
         .TX_HDR_NONPAY_LEN             (wTxHdrNonpayLen[`SIG_NONPAY_W-1:0]),
         .TX_HDR_PACKET_LEN             (wTxHdrPacketLen[`SIG_PACKETLEN_W-1:0]),
         .TX_PKT_READY                  (TX_PKT_READY),
         /*AUTOINST*/
         // Inputs
         .CLK                           (CLK),
         .RST_IN                        (RST_IN));

endmodule