
module regfile_1024bit (
    input  wire         clk,       // clock
    input  wire         rw,        // 1 = write, 0 = read
    input  wire         sel,       // 0 = lower 512 bits, 1 = upper 512 bits
    input  wire [511:0] data_in,   // data input
    output reg  [511:0] data_out   // data output (synchronous)
);

    // Single 1024-bit register storage
    reg [1023:0] regfile;

    always @(posedge clk) begin
        if (rw) begin
            // Write operation
            if (sel) begin
                regfile[1023:512] <= data_in;  // write upper 512 bits
            end else begin
                regfile[511:0]   <= data_in;   // write lower 512 bits
	    end
        end else begin
            // Read operation (synchronous output)
            if (sel) begin
                data_out <= regfile[1023:512]; // read upper 512 bits
            end else begin 
                data_out <= regfile[511:0];    // read lower 512 bits
       	    end 
	end
    end

endmodule
