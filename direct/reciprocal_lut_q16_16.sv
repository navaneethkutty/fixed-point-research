`timescale 1ns/1ps

// ============================================================================
// Direct-LUT reciprocal, Q16.16, 4096-entry ROM
//
// High-frequency architecture adapted from the supplied Q8.24 reference.
//
// Pipeline:
//   P0 : input register
//   P1 : raw index calculation + range flags
//   P2 : final index clamp/register + per-lane index replication
//   P3/P4 : four native x9 XPM block-ROM lanes, READ_LATENCY_A=2
//   P5 : final output register
//
// Four 4096x9 lanes reconstruct one 32-bit Q16.16 output.
//
// Input range : 0.5 to 2.5
// LUT entries : 4096
// Algorithm   : Pure Direct LUT, NO interpolation
// Target      : 400 MHz (2.500 ns)
// ============================================================================

module reciprocal_direct_lut_q16_16 #(
    parameter int IDX_BITS = 12,
    parameter int SHIFT    = 5
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,

    output logic        valid_out,
    output logic [31:0] recip_out
);

    localparam logic [31:0] X_LO = 32'h0000_8000; // 0.5 Q16.16
    localparam logic [31:0] X_HI = 32'h0002_8000; // 2.5 Q16.16

    localparam int N = (1 << IDX_BITS);

    // X_LO >> 5 = 1024.
    //
    // The extra index bit allows raw index 4096 at x = 2.5
    // to be detected and saturated to valid address 4095.
    localparam logic [IDX_BITS:0] LO_SHIFTED_CONST = 13'd1024;


    // ========================================================================
    // P0 - INPUT REGISTER
    // ========================================================================

    logic [31:0] x_r0;
    logic        v_r0;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            x_r0 <= '0;
            v_r0 <= 1'b0;
        end

        else begin
            x_r0 <= x_in;
            v_r0 <= valid_in;
        end

    end


    // ========================================================================
    // P1 - RAW INDEX GENERATION
    // ========================================================================

    logic                  below_r0;
    logic                  way_above;

    logic [IDX_BITS:0]     x_index_field;
    logic [IDX_BITS:0]     idx_raw_comb;

    always_comb begin

        below_r0 =
            (x_r0 < X_LO);

        way_above =
            |x_r0[31:(SHIFT + IDX_BITS + 1)];

        x_index_field =
            x_r0[(SHIFT + IDX_BITS) -: (IDX_BITS + 1)];

        idx_raw_comb =
            x_index_field - LO_SHIFTED_CONST;

    end


    logic [IDX_BITS:0] idx_raw_r1;
    logic              below_r0_r1;
    logic              way_above_r1;
    logic              v_r1;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            idx_raw_r1   <= '0;
            below_r0_r1  <= 1'b0;
            way_above_r1 <= 1'b0;
            v_r1         <= 1'b0;

        end

        else begin

            idx_raw_r1   <= idx_raw_comb;
            below_r0_r1  <= below_r0;
            way_above_r1 <= way_above;
            v_r1         <= v_r0;

        end

    end


    // ========================================================================
    // P2 - FINAL LUT ADDRESS
    // ========================================================================

    logic [IDX_BITS-1:0] idx_comb;
    logic [IDX_BITS-1:0] idx_r2;

    logic v_r2;

    always_comb begin

        if (below_r0_r1)

            idx_comb = '0;

        else if (way_above_r1 || idx_raw_r1[IDX_BITS])

            idx_comb = N - 1;

        else

            idx_comb = idx_raw_r1[IDX_BITS-1:0];

    end


    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            idx_r2 <= '0;
            v_r2   <= 1'b0;
        end

        else begin

            idx_r2 <= idx_comb;
            v_r2   <= v_r1;
        end

    end


    // ========================================================================
    // ADDRESS FANOUT REPLICATION
    //
    // One registered copy per BRAM lane.
    // ========================================================================

    logic [IDX_BITS-1:0] idx_r2_b0;
    logic [IDX_BITS-1:0] idx_r2_b1;
    logic [IDX_BITS-1:0] idx_r2_b2;
    logic [IDX_BITS-1:0] idx_r2_b3;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            idx_r2_b0 <= '0;
            idx_r2_b1 <= '0;
            idx_r2_b2 <= '0;
            idx_r2_b3 <= '0;

        end

        else begin

            idx_r2_b0 <= idx_comb;
            idx_r2_b1 <= idx_comb;
            idx_r2_b2 <= idx_comb;
            idx_r2_b3 <= idx_comb;

        end

    end


    // ========================================================================
    // P3/P4 - FOUR NATIVE x9 BRAM ROM LANES
    //
    // 4096 x 9 = 36864 bits
    //
    // Each lane maps naturally onto one RAMB36E1 x9 organization.
    //
    // Only bits [7:0] of each lane are used.
    // Bit [8] exists only to use the native x9 BRAM organization.
    // ========================================================================

    logic [8:0] rom_dout_b0;
    logic [8:0] rom_dout_b1;
    logic [8:0] rom_dout_b2;
    logic [8:0] rom_dout_b3;


    // ------------------------------------------------------------------------
    // BYTE LANE 0
    // ------------------------------------------------------------------------

    xpm_memory_sprom #(

        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),

        .MEMORY_INIT_FILE    ("direct_lut_b0_x9.mem"),
        .MEMORY_INIT_PARAM   (""),

        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),

        .MEMORY_SIZE         (9*N),

        .MESSAGE_CONTROL     (0),

        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),

        .RST_MODE_A          ("SYNC"),

        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),

        .WAKEUP_TIME         ("disable_sleep")

    ) u_rom_b0 (

        .douta            (rom_dout_b0),
        .clka             (clk),
        .addra            (idx_r2_b0),

        .ena              (1'b1),
        .regcea           (1'b1),

        .rsta             (1'b0),
        .sleep            (1'b0),

        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)

    );


    // ------------------------------------------------------------------------
    // BYTE LANE 1
    // ------------------------------------------------------------------------

    xpm_memory_sprom #(

        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),

        .MEMORY_INIT_FILE    ("direct_lut_b1_x9.mem"),
        .MEMORY_INIT_PARAM   (""),

        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),

        .MEMORY_SIZE         (9*N),

        .MESSAGE_CONTROL     (0),

        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),

        .RST_MODE_A          ("SYNC"),

        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),

        .WAKEUP_TIME         ("disable_sleep")

    ) u_rom_b1 (

        .douta            (rom_dout_b1),
        .clka             (clk),
        .addra            (idx_r2_b1),

        .ena              (1'b1),
        .regcea           (1'b1),

        .rsta             (1'b0),
        .sleep            (1'b0),

        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)

    );


    // ------------------------------------------------------------------------
    // BYTE LANE 2
    // ------------------------------------------------------------------------

    xpm_memory_sprom #(

        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),

        .MEMORY_INIT_FILE    ("direct_lut_b2_x9.mem"),
        .MEMORY_INIT_PARAM   (""),

        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),

        .MEMORY_SIZE         (9*N),

        .MESSAGE_CONTROL     (0),

        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),

        .RST_MODE_A          ("SYNC"),

        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),

        .WAKEUP_TIME         ("disable_sleep")

    ) u_rom_b2 (

        .douta            (rom_dout_b2),
        .clka             (clk),
        .addra            (idx_r2_b2),

        .ena              (1'b1),
        .regcea           (1'b1),

        .rsta             (1'b0),
        .sleep            (1'b0),

        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)

    );


    // ------------------------------------------------------------------------
    // BYTE LANE 3
    // ------------------------------------------------------------------------

    xpm_memory_sprom #(

        .ADDR_WIDTH_A        (IDX_BITS),
        .AUTO_SLEEP_TIME     (0),
        .CASCADE_HEIGHT      (1),
        .ECC_MODE            ("no_ecc"),

        .MEMORY_INIT_FILE    ("direct_lut_b3_x9.mem"),
        .MEMORY_INIT_PARAM   (""),

        .MEMORY_OPTIMIZATION ("true"),
        .MEMORY_PRIMITIVE    ("block"),

        .MEMORY_SIZE         (9*N),

        .MESSAGE_CONTROL     (0),

        .READ_DATA_WIDTH_A   (9),
        .READ_LATENCY_A      (2),
        .READ_RESET_VALUE_A  ("0"),

        .RST_MODE_A          ("SYNC"),

        .SIM_ASSERT_CHK      (0),
        .USE_MEM_INIT        (1),

        .WAKEUP_TIME         ("disable_sleep")

    ) u_rom_b3 (

        .douta            (rom_dout_b3),
        .clka             (clk),
        .addra            (idx_r2_b3),

        .ena              (1'b1),
        .regcea           (1'b1),

        .rsta             (1'b0),
        .sleep            (1'b0),

        .injectsbiterra   (1'b0),
        .injectdbiterra   (1'b0)

    );


    // ========================================================================
    // RECONSTRUCT 32-BIT Q16.16 RESULT
    // ========================================================================

    logic [31:0] rom_dout;

    assign rom_dout = {

        rom_dout_b3[7:0],
        rom_dout_b2[7:0],
        rom_dout_b1[7:0],
        rom_dout_b0[7:0]

    };


    // ========================================================================
    // VALID PIPELINE
    //
    // Matches the two-cycle XPM ROM latency.
    // ========================================================================

    logic v_r3a;
    logic v_r3;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            v_r3a <= 1'b0;
            v_r3  <= 1'b0;

        end

        else begin

            v_r3a <= v_r2;
            v_r3  <= v_r3a;

        end

    end


    // ========================================================================
    // FINAL OUTPUT REGISTER
    // ========================================================================

    logic [31:0] recip_r4;
    logic        v_r4;

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            recip_r4 <= '0;
            v_r4     <= 1'b0;

        end

        else begin

            recip_r4 <= rom_dout;
            v_r4     <= v_r3;

        end

    end


    assign recip_out = recip_r4;
    assign valid_out = v_r4;

endmodule