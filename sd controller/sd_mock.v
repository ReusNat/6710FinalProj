// sd_mock.v – SPI SD-Card mock with *full* debug visibility
// Verilog-2001 only – NO SystemVerilog
`timescale 1ns/1ps
module sd_mock (
    input wire clk,
    input wire rst_n,
    input wire spi_cs_n,
    input wire spi_clk,
    input wire spi_mosi,
    output reg spi_miso
);
    // -----------------------------------------------------------------
    // Memory (64 KB)
    // -----------------------------------------------------------------
    reg [7:0] memory [0:65535];
    integer i;
    // -----------------------------------------------------------------
    // SPI Reception
    // -----------------------------------------------------------------
    reg [7:0] rx_shift;
    reg [7:0] rx_byte;
    reg [3:0] bit_cnt;
    reg rx_valid;
    reg cmd_active;
    // -----------------------------------------------------------------
    // Command parsing
    // -----------------------------------------------------------------
    reg [5:0] cmd;
    reg [31:0] cmd_arg;
    reg [7:0] cmd_crc;
    reg [7:0] cmd_buf [0:5];
    integer cmd_idx;
    // -----------------------------------------------------------------
    // Response handling
    // -----------------------------------------------------------------
    reg [7:0] resp_buf [0:15];
    integer resp_idx;
    integer resp_len;
    reg sending_resp;
    // -----------------------------------------------------------------
    // MISO transmission (bit-serial)
    // -----------------------------------------------------------------
    reg [7:0] tx_shift;
    reg [3:0] tx_bit_cnt;  // Changed to 3:0 for 0-8
    reg tx_active;
    // -----------------------------------------------------------------
    // Data-token / read/write state
    // -----------------------------------------------------------------
    reg data_token_phase;
    reg [6:0] data_byte_cnt;
    reg [31:0] block_addr;
    // -----------------------------------------------------------------
    // Flags
    // -----------------------------------------------------------------
    reg inited;
    reg is_sd2;
    reg crc_enabled;
    // -----------------------------------------------------------------
    // SPI clock edge detection
    // -----------------------------------------------------------------
    reg spi_clk_dly;
    wire spi_clk_rising = spi_clk & ~spi_clk_dly;
    wire spi_clk_falling = ~spi_clk & spi_clk_dly;
    // -----------------------------------------------------------------
    // ---------------------- DEBUG MONITORING ----------------------
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (!spi_cs_n && spi_clk_rising)
            $display("[%t] DBG: MOSI bit = %b (bit_cnt=%0d)", $time, spi_mosi, bit_cnt);
    end
    always @(posedge clk) begin
        if (rx_valid) begin
            if (cmd_active && cmd_idx <= 5)
                $display("[%t] DBG: CMD Byte %0d = 0x%02h", $time, cmd_idx, rx_byte);
            else if (cmd_active)
                $display("[%t] DBG: CMD CRC = 0x%02h", $time, rx_byte);
            else
                $display("[%t] DBG: DATA Byte %0d = 0x%02h", $time, data_byte_cnt, rx_byte);
        end
    end
    always @(posedge clk) begin
        if (!spi_cs_n && spi_clk_falling && tx_active)
            $display("[%t] DBG: MISO bit = %b (tx_bit_cnt=%0d)", $time, spi_miso, tx_bit_cnt);
    end
    always @(posedge clk) begin
        if (sending_resp && !tx_active && resp_idx < resp_len)
            $display("[%t] DBG: START RESPONSE byte %0d = 0x%02h", $time, resp_idx, resp_buf[resp_idx]);
        if (sending_resp && resp_idx >= resp_len && !tx_active)
            $display("[%t] DBG: END RESPONSE", $time);
        if (data_token_phase && cmd == 6'd17 && !tx_active && data_byte_cnt == 0)
            $display("[%t] DBG: START READ DATA (token 0xFE)", $time);
        if (data_token_phase && cmd == 6'd17 && data_byte_cnt == 64)
            $display("[%t] DBG: END READ DATA (CRC follows)", $time);
    end
    // -----------------------------------------------------------------
    // SPI BYTE RECEPTION (sample on rising edge)
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_shift <= 8'h00;
            bit_cnt <= 4'd0;
            rx_valid <= 1'b0;
            rx_byte <= 8'hFF;
            spi_clk_dly <= 1'b0;
        end else begin
            spi_clk_dly <= spi_clk;
            rx_valid <= 1'b0;
            if (!spi_cs_n) begin
                if (spi_clk_rising) begin
                    rx_shift <= {rx_shift[6:0], spi_mosi};
                    bit_cnt <= bit_cnt + 1'd1;
                    if (bit_cnt == 4'd7) begin
                        rx_byte <= {rx_shift[6:0], spi_mosi};
                        rx_valid <= 1'b1;
                        bit_cnt <= 4'd0;
                    end
                end
            end else begin
                bit_cnt <= 4'd0;
            end
        end
    end
    // -----------------------------------------------------------------
    // MAIN STATE MACHINE & MISO TRANSMISSION
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_miso <= 1'b1;
            cmd_active <= 1'b0;
            cmd_idx <= 0;
            sending_resp <= 1'b0;
            resp_idx <= 0;
            resp_len <= 0;
            data_token_phase <= 1'b0;
            data_byte_cnt <= 7'd0;
            inited <= 1'b0;
            is_sd2 <= 1'b0;
            crc_enabled <= 1'b1;
            block_addr <= 32'd0;
            tx_shift <= 8'hFF;
            tx_bit_cnt <= 4'd0;
            tx_active <= 1'b0;
            for (i = 0; i < 16; i = i + 1) resp_buf[i] <= 8'hFF;
            for (i = 0; i < 65536; i = i + 1) memory[i] <= i[7:0] ^ 8'hA5;
        end else begin
            // Default high
            spi_miso <= 1'b1;
            // ---- Load next response byte ----
            if (sending_resp && !tx_active && resp_idx < resp_len) begin
                tx_shift <= resp_buf[resp_idx];
                tx_active <= 1'b1;
                tx_bit_cnt <= 4'd0;
            end
            // ---- Load data token / read data ----
            else if (data_token_phase && cmd == 6'd17 && !tx_active) begin
                if (data_byte_cnt == 7'd0) begin
                    tx_shift <= 8'hFE;
                    data_byte_cnt <= 7'd1;
                end else if (data_byte_cnt <= 7'd64) begin
                    tx_shift <= memory[block_addr + data_byte_cnt - 1];
                    data_byte_cnt <= data_byte_cnt + 1;
                    if (data_byte_cnt == 7'd64) begin
                        resp_buf[0] <= 8'hFF;
                        resp_buf[1] <= 8'hFF;
                        resp_len <= 2;
                        sending_resp <= 1'b1;
                        resp_idx <= 0;
                        data_token_phase <= 1'b0;
                    end
                end else begin
                    tx_active <= 1'b0;
                end
                tx_active <= 1'b1;
                tx_bit_cnt <= 4'd0;
            end
            // ---- Shift out (adapted from slave emulation) ----
            if (tx_active) begin
                if (spi_clk_rising) begin
                    tx_shift <= {tx_shift[6:0], 1'b0};
                    tx_bit_cnt <= tx_bit_cnt + 1'd1;
                    if (tx_bit_cnt == 4'd7) begin
                        tx_active <= 1'b0;
                        if (sending_resp) resp_idx <= resp_idx + 1;
                    end
                end
                if (spi_clk_falling) begin
                    spi_miso <= tx_shift[7];
                end
            end
            // ---- Finish response ----
            if (sending_resp && resp_idx >= resp_len && !tx_active) begin
                sending_resp <= 1'b0;
            end
            // -----------------------------------------------------------------
            // COMMAND PARSING
            // -----------------------------------------------------------------
            if (rx_valid && !spi_cs_n) begin
                if (!cmd_active && rx_byte[7:6] == 2'b01) begin
                    cmd_active <= 1'b1;
                    cmd_idx <= 1; // next byte goes into index 1
                    cmd_buf[0] <= rx_byte;
                    $display("[%t] SD_MOCK: === RECV CMD%0d ===", $time, rx_byte[5:0]);
                end else if (cmd_active) begin
                    cmd_buf[cmd_idx] <= rx_byte;
                    if (cmd_idx == 5) begin
                        cmd <= cmd_buf[0][5:0];
                        cmd_arg <= {cmd_buf[1],cmd_buf[2],cmd_buf[3],cmd_buf[4]};
                        cmd_crc <= rx_byte;
                        cmd_active <= 1'b0;
                        // default R1
                        resp_buf[0] <= inited ? 8'h00 : 8'h01;
                        resp_len <= 1;
                        sending_resp <= 1'b1;
                        resp_idx <= 0;
                        data_token_phase <= 1'b0;
                        case (cmd)
                            6'd0: begin
                                $display("[%t] SD_MOCK: CMD0 -> R1=0x01 (idle)", $time);
                                inited <= 1'b0;
                            end
                            6'd8: begin
                                if (cmd_arg[11:8]==4'h1 && cmd_arg[7:0]==8'hAA) begin
                                    resp_buf[0] <= 8'h01;
                                    resp_buf[1] <= 8'h00;
                                    resp_buf[2] <= 8'h00;
                                    resp_buf[3] <= 8'h01;
                                    resp_buf[4] <= 8'hAA;
                                    resp_len <= 5;
                                    is_sd2 <= 1'b1;
                                    $display("[%t] SD_MOCK: CMD8 -> R7 valid", $time);
                                end else begin
                                    resp_buf[0] <= 8'h05;
                                    resp_len <= 1;
                                end
                            end
                            6'd59: begin
                                crc_enabled <= cmd_arg[0];
                                resp_buf[0] <= 8'h00;
                                $display("[%t] SD_MOCK: CMD59 -> CRC %s", $time,
                                        cmd_arg[0]?"ON":"OFF");
                            end
                            6'd55: begin
                                resp_buf[0] <= 8'h01;
                                $display("[%t] SD_MOCK: CMD55 -> R1=0x01", $time);
                            end
                            6'd41: begin
                                if (inited) resp_buf[0] <= 8'h00;
                                else if (is_sd2 && cmd_arg[30]) resp_buf[0] <= 8'h00;
                                else resp_buf[0] <= 8'h01;
                                if (resp_buf[0]==8'h00) begin
                                    inited <= 1'b1;
                                    $display("[%t] SD_MOCK: ACMD41 -> Initialized!", $time);
                                end
                            end
                            6'd58: begin
                                resp_buf[0] <= 8'h00;
                                resp_buf[1] <= 8'hC0;
                                resp_buf[2] <= 8'hFF;
                                resp_buf[3] <= 8'h80;
                                resp_buf[4] <= 8'h00;
                                resp_len <= 5;
                                $display("[%t] SD_MOCK: CMD58 -> OCR", $time);
                            end
                            6'd16: begin
                                if (cmd_arg==32'd64) begin
                                    resp_buf[0] <= 8'h00;
                                    $display("[%t] SD_MOCK: CMD16 -> Block len 64", $time);
                                end else begin
                                    resp_buf[0] <= 8'h05;
                                end
                            end
                            6'd17: begin
                                block_addr <= cmd_arg;
                                resp_buf[0] <= 8'h00;
                                data_token_phase <= 1'b1;
                                data_byte_cnt <= 7'd0;
                                $display("[%t] SD_MOCK: CMD17 -> Read block 0x%08h", $time, cmd_arg);
                            end
                            6'd24: begin
                                block_addr <= cmd_arg;
                                resp_buf[0] <= 8'h00;
                                data_token_phase <= 1'b1;
                                data_byte_cnt <= 7'd0;
                                $display("[%t] SD_MOCK: CMD24 -> Write block 0x%08h", $time, cmd_arg);
                            end
                            default: begin
                                resp_buf[0] <= 8'h05;
                                $display("[%t] SD_MOCK: CMD%0d -> Unsupported", $time, cmd);
                            end
                        endcase
                    end else begin
                        cmd_idx <= cmd_idx + 1;
                    end
                end
                // ---- WRITE DATA handling (after CMD24) ----
                else if (data_token_phase && cmd == 6'd24) begin
                    if (data_byte_cnt == 7'd0 && rx_byte == 8'hFE) begin
                        $display("[%t] SD_MOCK: Data token 0xFE (write start)", $time);
                        data_byte_cnt <= 7'd1;
                    end else if (data_byte_cnt > 0 && data_byte_cnt <= 7'd64) begin
                        memory[block_addr + data_byte_cnt - 1] <= rx_byte;
                        $display("[%t] SD_MOCK: WRITE[0x%03h] = 0x%02h",
                                 $time, block_addr + data_byte_cnt - 1, rx_byte);
                        data_byte_cnt <= data_byte_cnt + 1;
                        if (data_byte_cnt == 7'd64) begin
                            resp_buf[0] <= 8'h05; // data response
                            resp_len <= 1;
                            sending_resp <= 1'b1;
                            resp_idx <= 0;
                            data_token_phase <= 1'b0;
                            $display("[%t] SD_MOCK: Write complete -> Data Response 0x05", $time);
                        end
                    end
                end
            end
        end
    end
endmodule