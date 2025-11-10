module spi_transactor (
    input wire clk,
    input wire rst_n,
    input wire spi_clk_rising,
    input wire spi_clk_falling,
    input wire start,
    input wire [7:0] tx_data,
    output reg [7:0] rx_data,
    output reg done,
    output reg spi_mosi,
    input wire spi_miso
);
    reg [7:0] tx_shift;
    reg [7:0] rx_shift;
    reg [3:0] bit_cnt;
    reg busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_mosi <= 1'b1;
            rx_data  <= 8'h00;
            tx_shift <= 8'h00;
            rx_shift <= 8'h00;
            bit_cnt  <= 4'd0;
            done     <= 1'b0;
            busy     <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy     <= 1'b1;
                tx_shift <= tx_data;
                rx_shift <= 8'h00;
                bit_cnt  <= 4'd0;
                spi_mosi <= tx_data[7];  // preload MSB
            end
            else if (busy) begin

                // Sample MISO on rising edge
                if (spi_clk_rising) begin
                    rx_shift <= {rx_shift[6:0], spi_miso};

                    // Done after capturing final bit
                    if (bit_cnt == 8) begin
                        rx_data  <= {rx_shift[6:0], spi_miso};
                        done     <= 1'b1;
                        busy     <= 1'b0;
                    end
                end

                // Shift TX on falling edge
                if (spi_clk_falling) begin
                    if (bit_cnt < 7) begin
                        tx_shift <= {tx_shift[6:0], 1'b0};
                        spi_mosi <= tx_shift[6];
                        bit_cnt  <= bit_cnt + 1'd1;
                    end else if (bit_cnt == 7) begin
                        // Shift final bit, then wait one more rising edge for last MISO sample
                        spi_mosi <= 1'b1;
                        bit_cnt  <= bit_cnt + 1'd1;  // goes to 8
                    end
                end
            end
        end
    end
endmodule
