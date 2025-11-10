`timescale 1ns/1ps
module tb_xorEncr_min;

  // DUT I/O 
  reg  clk = 0, rst = 1, start = 0, rw_flag = 0;
  wire done;

  // SD-side (TB drives these)
  reg  [511:0] sd_data_in = 0;
  wire [511:0] sd_data_out;
  reg         sd_data_valid = 0;
  reg         sd_ready = 0;

  // Regfile side
  wire        reg_file_rw;         // observed only
  wire        reg_file_sel;        // observed only
  reg  [511:0] reg_file_data_out = 0;

  // Test vectors
  reg [511:0] P;    // plaintext
  reg [511:0] K;    // key
  reg [511:0] C;    // encrytpted text
  reg [511:0] P2;   // decrypted plaintext

  // DUT
  xorEncr#(.DATA_WIDTH(512), .KEY_WIDTH(512)) dut (
    .clk, .rst, .start, .rw_flag, .done,
    .sd_data_in, .sd_data_out, .sd_data_valid, .sd_ready,
    .reg_file_rw, .reg_file_sel, .reg_file_data_out
  );

  // 100 MHz clock (10 ns period)
  always #5 clk = ~clk;

  initial begin
    // optional VCD dump     
    $dumpvars(0, tb_xorEncr_min);

    // Reset 
    repeat(3) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // ENCRYPT 
    // Flow: IDLE -> READ_DATA -> READ_KEY -> WAIT_KEY -> ENCRYPT -> WRITE_ENCRYPTED -> DONE
    P = 512'h4F12AD55CC09E7D24C8A1190EEB94AC11122DFFE88A03C55AAEE77FA44D921BBE9F7C02200419AC9D2B311FE55C0A4DE8899FF10AABBCDEE00112233445566FF;
    K = 512'hA9F1C3D55E8B44129F2A77E63BC8D1F4C5B2A8E7129DFF6678A03CD44F12B9AE1C55F8D9AFA7E332991AD0BC5556EAA39CD47E21B08861D3FF20A98C67421D11;

    reg_file_data_out = K;    // mock regfile: provide key
    rw_flag = 1'b1;           // 1 = encrypt
    start   = 1'b1; @(posedge clk); start = 1'b0;

    // Feed one input word from "SD"
    sd_data_in    = P;
    sd_data_valid = 1'b1; @(posedge clk); sd_data_valid = 1'b0;

    // Park in WRITE_ENCRYPTED to sample output
    sd_ready = 1'b0; @(posedge clk);
    repeat (4) @(posedge clk); 
    if (sd_data_out !== (P ^ K))
      $fatal(1, "ENCRYPT mismatch: got=0x%0h exp=0x%0h", sd_data_out, (P ^ K));
    C = sd_data_out;

    // Let DUT finish (DONE is a 1-cycle pulse)
    sd_ready = 1'b1; @(posedge clk); sd_ready = 1'b0;
    wait (done === 1'b1); @(posedge clk);

    // DECRYPT 
    // Flow: IDLE -> READ_ENCRYPTED -> READ_KEY -> WAIT_KEY -> DECRYPT -> WRITE_DECRYPTED -> DONE
    reg_file_data_out = K; // same key
    rw_flag = 1'b0; // 0 = decrypt
    start   = 1'b1; @(posedge clk); start = 1'b0;

    // Feed the encrypted text back in
    sd_data_in    = C;
    sd_data_valid = 1'b1; @(posedge clk); sd_data_valid = 1'b0;

    // Park in WRITE_DECRYPTED to sample output
    sd_ready = 1'b0; @(posedge clk);
    repeat (4) @(posedge clk); 
    if (sd_data_out !== (C ^ K))
      $fatal(1, "DECRYPT mismatch: got=0x%0h exp=0x%0h", sd_data_out, (C ^ K));
    P2 = sd_data_out;

    // Finish + final roundtrip check
    sd_ready = 1'b1; @(posedge clk); sd_ready = 1'b0;
    wait (done === 1'b1); @(posedge clk);

    if (P2 !== P)
      $fatal(1, "Roundtrip failed: P=0x%0h, C=0x%0h, P2=0x%0h", P, C, P2);

    $display("PASS  P=0x%0h -> C=0x%0h -> P2=0x%0h", P, C, P2);
    #20 $finish;
  end
endmodule