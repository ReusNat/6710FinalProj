// SPI Transactor Testbench (fixed MISO timing)
`timescale 1ns/1ps
module spi_transactor_tb;

    reg clk;
    reg rst_n;
    reg start;
    reg spi_clk;
    reg spi_clk_dly;
    reg spi_clk_rising;
    reg spi_clk_falling;

    reg [7:0] tx_data;
    wire [7:0] rx_data;
    wire done;
    wire spi_mosi;
    wire spi_miso;

    // === Instantiate DUT ===
    spi_transactor dut (
        .clk(clk),
        .rst_n(rst_n),
        .spi_clk_rising(spi_clk_rising),
        .spi_clk_falling(spi_clk_falling),
        .start(start),
        .tx_data(tx_data),
        .rx_data(rx_data),
        .done(done),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    integer error_cnt = 0;

    // === Clock generation ===
    always #10 clk = ~clk;       // 50 MHz
    always #80 spi_clk = ~spi_clk; // SPI clock ~6.25 MHz

    // Edge detection
    always @(posedge clk) begin
        spi_clk_dly <= spi_clk;
        spi_clk_rising  <= (!spi_clk_dly && spi_clk);
        spi_clk_falling <= ( spi_clk_dly && !spi_clk);
    end

    // === SPI slave emulation ===
    reg [7:0] slave_data;
    reg [7:0] slave_shift;
    reg [3:0] slave_cnt;
    reg slave_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_miso <= 1'b1;
            slave_shift <= 8'h00;
            slave_cnt <= 4'd0;
            slave_active <= 1'b0;
        end else begin
            if (start && !slave_active) begin
                slave_active <= 1'b1;
                slave_shift <= slave_data;
                slave_cnt <= 4'd0;
            end else if (slave_active) begin
                // shift on rising edge, output next bit on falling edge (fix)
                if (spi_clk_rising) begin
                    slave_shift <= {slave_shift[6:0], 1'b0};
                    slave_cnt <= slave_cnt + 1'b1;
                    if (slave_cnt == 4'd7)
                        slave_active <= 1'b0;
                end
                if (spi_clk_falling)
                    spi_miso <= slave_shift[7];  // drive MISO *after* shift
            end else begin
                spi_miso <= 1'b1; // idle high
            end
        end
    end

    // === Debug monitor ===
    always @(posedge spi_clk or negedge spi_clk) begin
        $display("[%t] SPI %s: MOSI=%b  MISO=%b  (DUT_RX=%02h  SLAVE_SHIFT=%02h)",
                 $time,
                 spi_clk ? "RISE" : "FALL",
                 spi_mosi,
                 spi_miso,
                 rx_data,
                 slave_shift);
    end

    // === Test sequence ===
    initial begin
        clk = 0; spi_clk = 0; spi_clk_dly = 0;
        rst_n = 0; start = 0;
        tx_data = 8'h00; slave_data = 8'h00;
        spi_miso = 1;
        #100 rst_n = 1;

        // ---- Test 1 ----
        #200;
        tx_data = 8'h55;
        slave_data = 8'hA5;
        start = 1; #20; start = 0;
        wait(done);
        #10;
        $display("[%t] Test 1: TX=0x%h RX=0x%h", $time, tx_data, rx_data);
        if (rx_data !== 8'hA5) begin
            error_cnt = error_cnt + 1;
            $error("Test1: RX mismatch: exp 0xA5, got 0x%h", rx_data);
        end

        // ---- Test 2 ----
        #200;
        tx_data = 8'hAA;
        slave_data = 8'h3C;
        start = 1; #20; start = 0;
        wait(done);
        #10;
        $display("[%t] Test 2: TX=0x%h RX=0x%h", $time, tx_data, rx_data);
        if (rx_data !== 8'h3C) begin
            error_cnt = error_cnt + 1;
            $error("Test2: RX mismatch: exp 0x3C, got 0x%h", rx_data);
        end

        // ---- Test 3 ----
        #200;
        tx_data = 8'h33;
        slave_data = 8'h4A;
        start = 1; #20; start = 0;
        wait(done);
        #10;
        $display("[%t] Test 3: TX=0x%h RX=0x%h", $time, tx_data, rx_data);
        if (rx_data !== 8'h4A) begin
            error_cnt = error_cnt + 1;
            $error("Test3: RX mismatch: exp 0x4A, got 0x%h", rx_data);
        end

        #100;
        if (error_cnt == 0)
            $display("=== spi_transactor_tb PASSED ===");
        else
            $display("=== spi_transactor_tb FAILED (errors=%0d) ===", error_cnt);
        $finish;
    end

endmodule
