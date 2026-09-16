`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 16.09.2026 21:44:36
// Design Name:
// Module Name: reciprocal_interp_q16_16
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


// ============================================================================
// reciprocal_interp_q16_16
//
// Q16.16 reciprocal using:
//   2048-entry seed LUT
//   2048-entry slope LUT
//   Linear interpolation
//   DSP48E1 multiplication
//   Fully pipelined chunked addition
//   Both-bound input clamping
//   Output saturation
//
// Input range:
//   x in [0.5, 2.5]
//
// Fixed-point format:
//   Input       : Q16.16
//   Seed        : Q16.16, 32-bit
//   Slope       : signed 18-bit
//   Fraction    : normalized 11-bit [0..2047]
//
// Interpolation:
//
//   y = seed + ((slope * frac) >>> 11)
//
// Pipeline:
//
//   P0  : register input + above/below range detection
//   P1  : direct index/fraction generation
//   P2  : register LUT address + fraction
//   P3  : BRAM internal latency
//   P4  : BRAM output decoupling
//   P5  : DSP A/B registers
//   P6  : DSP M register
//   P7  : DSP P register
//   P8  : DSP output decoupling
//   P9  : addition chunk 0
//   P10 : addition chunk 1
//   P11 : addition chunk 2
//   P12 : addition chunk 3
//   P13 : saturation comparison
//   P14 : saturation select
//
// Throughput: 1 result / cycle
// ============================================================================


module reciprocal_interp_q16_16 #(

    parameter int IDX_BITS = 11,

    // Q16.16 input:
    //
    // Total interval:
    //
    //   2.5 - 0.5 = 2.0
    //
    // In Q16.16:
    //
    //   2.0 * 65536 = 131072 = 2^17
    //
    // 2048 intervals:
    //
    //   2^17 / 2^11 = 2^6
    //
    // Therefore address extraction uses >> 6.
    parameter int SHIFT = 6,

    // We use a normalized 11-bit interpolation fraction.
    //
    // Raw interval remainder:
    //
    //   0 ... 63
    //
    // Normalized:
    //
    //   0 ... 2047
    //
    // frac = remainder << 5
    parameter int FRAC_BITS = 11,

    parameter int SLOPE_BITS = 18

) (

    input  logic        clk,
    input  logic        rst,

    input  logic        valid_in,
    input  logic [31:0] x_in,

    output logic        valid_out,
    output logic [31:0] recip_out

);


    // ========================================================================
    // Constants
    // ========================================================================

    localparam logic [31:0] X_LO =
        32'h0000_8000;       // 0.5 in Q16.16

    localparam logic [31:0] X_HI =
        32'h0002_8000;       // 2.5 in Q16.16

    localparam logic [31:0] RECIP_LO =
        32'h0002_0000;       // 2.0 in Q16.16

    localparam logic [31:0] RECIP_HI =
        32'h0000_6666;       // 0.4 in Q16.16

    localparam int N =
        (1 << IDX_BITS);


 // ========================================================================
// P0
//
// Register input and range information.
//
// The upper-bound decision is intentionally generated here rather than
// in P1. This prevents the x_r0 == X_HI comparison from being propagated
// into the set/reset control network of the P1 fraction registers.
//
// Both x >= 2.5 and x == 2.5 map to the same final LUT point, so a single
// upper_clamp flag is sufficient.
//
// Lower bound:
//   x < 0.5
//
// Upper bound:
//   x >= 2.5
// ========================================================================

logic [31:0] x_r0;

logic v_r0;

logic below_r0;
logic upper_clamp_r0;

logic below_comb_p0;
logic upper_clamp_comb_p0;


always_comb begin

    // ---------------------------------------------------------------
    // Lower bound:
    //
    // Negative values are below range.
    //
    // For positive Q16.16 values:
    //   0.5 = 0x00008000
    //
    // Thus x < 0.5 when bits [30:15] are all zero.
    // ---------------------------------------------------------------

    below_comb_p0 =
        x_in[31] ||
        (x_in[30:15] == 16'd0);


    // ---------------------------------------------------------------
    // Upper bound:
    //
    // Both x = 2.5 and x > 2.5 clamp to the final LUT point.
    // Therefore use one >= comparison.
    // ---------------------------------------------------------------

    upper_clamp_comb_p0 =
        (x_in >= X_HI);

end


always_ff @(posedge clk) begin

    if (rst) begin

        x_r0          <= '0;
        v_r0          <= 1'b0;

        below_r0      <= 1'b0;
        upper_clamp_r0 <= 1'b0;

    end
    else begin

        x_r0          <= x_in;
        v_r0          <= valid_in;

        below_r0      <= below_comb_p0;
        upper_clamp_r0 <= upper_clamp_comb_p0;

    end

end
// ========================================================================
// P1
//
// Direct LUT index + interpolation fraction generation.
//
// Q16.16:
//   X_LO = 0.5
//   X_HI = 2.5
//
// 2048 intervals over [0.5, 2.5]:
//
//   interval = 2.0 / 2048
//            = 1 / 1024
//
// In Q16.16:
//
//   interval = 64 LSB
//
// Therefore for normal in-range inputs:
//
//   index = floor((x - 0.5) / 64)
//         = (x >> 6) - 512
//
// Hence:
//
//   index = x_r0[17:6] - 512
//
// The interpolation remainder is:
//
//   remainder = x_r0[5:0]
//
// Normalized to 11 bits:
//
//   frac = remainder << 5
//        = {x_r0[5:0], 5'b0}
//
// Range decisions are already registered in P0.
// This avoids a same-stage x_r0 comparator feeding the P1
// fraction/index registers.
// ========================================================================

logic [IDX_BITS-1:0]  idx_direct_comb;
logic [FRAC_BITS-1:0] frac_direct_comb;


// ------------------------------------------------------------------------
// P1 combinational logic
// ------------------------------------------------------------------------

always_comb begin

    // ---------------------------------------------------------------
    // Normal direct LUT index.
    //
    // x_r0[17:6] is a 12-bit interval count.
    // 512 corresponds to the 0.5 lower boundary.
    // ---------------------------------------------------------------

    idx_direct_comb =
        x_r0[17:6] - 12'd512;


    // ---------------------------------------------------------------
    // Direct normalized interpolation fraction.
    // ---------------------------------------------------------------

    frac_direct_comb =
        {x_r0[5:0], 5'b0};


    // ---------------------------------------------------------------
    // Lower clamp.
    // ---------------------------------------------------------------

    if (below_r0) begin

        idx_direct_comb  = 11'd0;
        frac_direct_comb = '0;

    end


    // ---------------------------------------------------------------
    // Upper clamp.
    //
    // upper_clamp_r0 includes:
    //
    //   x = 2.5
    //   x > 2.5
    //
    // Both use the final LUT point and maximum interpolation fraction.
    // ---------------------------------------------------------------

    else if (upper_clamp_r0) begin

        idx_direct_comb  = N - 1;
        frac_direct_comb = {FRAC_BITS{1'b1}};

    end

end


// ------------------------------------------------------------------------
// P1 registers
//
// These registers are IMPORTANT.
// They preserve the pipeline stage and therefore retain the measured
// 16-cycle latency of the architecture.
// ------------------------------------------------------------------------

(* dont_touch = "true", keep = "true", shreg_extract = "no" *)
logic [IDX_BITS-1:0] idx_direct_r1;

(* dont_touch = "true", keep = "true", shreg_extract = "no" *)
logic [FRAC_BITS-1:0] frac_direct_r1;

logic v_r1;


always_ff @(posedge clk) begin

    if (rst) begin

        idx_direct_r1  <= '0;
        frac_direct_r1 <= '0;
        v_r1           <= 1'b0;

    end
    else begin

        idx_direct_r1  <= idx_direct_comb;
        frac_direct_r1 <= frac_direct_comb;

        v_r1 <= v_r0;

    end

end


// ========================================================================
// P2
//
// Register the LUT address and interpolation fraction.
//
// No arithmetic is performed in P2.
// ========================================================================

logic [IDX_BITS-1:0]  idx_r2;
logic [FRAC_BITS-1:0] frac_r2;
logic                 v_r2;


always_ff @(posedge clk) begin

    if (rst) begin

        idx_r2  <= '0;
        frac_r2 <= '0;
        v_r2    <= 1'b0;

    end
    else begin

        idx_r2  <= idx_direct_r1;
        frac_r2 <= frac_direct_r1;

        v_r2 <= v_r1;

    end

end
    // ========================================================================
    // P3
    //
    // Block RAM LUTs.
    //
    // READ_LATENCY_A = 2.
    //
    // Seed:
    //   32-bit Q16.16
    //
    // Slope:
    //   18-bit signed
    // ========================================================================

    logic [31:0] seed_dout;

    logic signed [SLOPE_BITS-1:0] slope_dout;


    xpm_memory_sprom #(

        .ADDR_WIDTH_A       (IDX_BITS),

        .MEMORY_INIT_FILE   ("interp_seed.mem"),

        .MEMORY_PRIMITIVE   ("block"),

        .MEMORY_SIZE        (N * 32),

        .READ_DATA_WIDTH_A  (32),

        .READ_LATENCY_A     (2),

        .READ_RESET_VALUE_A ("0"),

        .RST_MODE_A         ("SYNC"),

        .USE_MEM_INIT       (1)

    ) seed_rom_inst (

        .clka   (clk),

        .ena    (1'b1),

        .regcea (1'b1),

        .rsta   (rst),

        .sleep  (1'b0),

        .addra  (idx_r2),

        .douta  (seed_dout)

    );


    xpm_memory_sprom #(

        .ADDR_WIDTH_A       (IDX_BITS),

        .MEMORY_INIT_FILE   ("interp_slope.mem"),

        .MEMORY_PRIMITIVE   ("block"),

        .MEMORY_SIZE        (N * SLOPE_BITS),

        .READ_DATA_WIDTH_A  (SLOPE_BITS),

        .READ_LATENCY_A     (2),

        .READ_RESET_VALUE_A ("0"),

        .RST_MODE_A         ("SYNC"),

        .USE_MEM_INIT       (1)

    ) slope_rom_inst (

        .clka   (clk),

        .ena    (1'b1),

        .regcea (1'b1),

        .rsta   (rst),

        .sleep  (1'b0),

        .addra  (idx_r2),

        .douta  (slope_dout)

    );


    // ========================================================================
    // Fraction pipeline
    //
    // Aligns the fraction with the two-cycle BRAM output.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [FRAC_BITS-1:0] frac_r3a;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [FRAC_BITS-1:0] frac_r3b;

    logic v_r3a;
    logic v_r3b;


    always_ff @(posedge clk) begin

        if (rst) begin

            frac_r3a <= '0;
            frac_r3b <= '0;

            v_r3a <= 1'b0;
            v_r3b <= 1'b0;

        end
        else begin

            frac_r3a <= frac_r2;
            frac_r3b <= frac_r3a;

            v_r3a <= v_r2;
            v_r3b <= v_r3a;

        end

    end


    // ========================================================================
    // P4
    //
    // Decouple BRAM outputs before entering DSP.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r4;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [17:0] slope_r4;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [FRAC_BITS-1:0] frac_r4;

    logic v_r4;


    always_ff @(posedge clk) begin

        if (rst) begin

            seed_r4  <= '0;
            slope_r4 <= '0;
            frac_r4  <= '0;

            v_r4 <= 1'b0;

        end
        else begin

            seed_r4  <= seed_dout;
            slope_r4 <= slope_dout;
            frac_r4  <= frac_r3b;

            v_r4 <= v_r3b;

        end

    end


    // ========================================================================
    // P5 / P6 / P7
    //
    // DSP48E1 performs ONLY:
    //
    //   product = slope * frac
    //
    // The final seed addition is performed in pipelined fabric.
    //
    // Fixed-point interpolation equation:
    //
    //   y = seed + ((slope * frac) >>> 11)
    //
    // Therefore the DSP product is shifted by 11 later.
    // ========================================================================

    logic signed [29:0] dsp_a_in;

    logic [17:0] dsp_b_in;

    logic signed [47:0] dsp_p_out;


    assign dsp_a_in =
        {{12{slope_r4[17]}}, slope_r4};


    assign dsp_b_in =
        {7'b0, frac_r4};


    DSP48E1 #(

        .A_INPUT            ("DIRECT"),

        .B_INPUT            ("DIRECT"),

        .USE_DPORT          ("FALSE"),

        .USE_MULT           ("MULTIPLY"),

        .USE_SIMD           ("ONE48"),

        .AREG               (1),

        .BREG               (1),

        .MREG               (1),

        .PREG               (1),

        .CREG               (0),

        .ADREG              (0),

        .ALUMODEREG         (0),

        .CARRYINREG         (0),

        .CARRYINSELREG      (0),

        .OPMODEREG          (0),

        .INMODEREG          (0),

        .DREG               (0),

        .ACASCREG           (1),

        .BCASCREG           (1)

    ) dsp_slope_mult_inst (

        .CLK                (clk),

        .A                  (dsp_a_in),

        .B                  (dsp_b_in),

        .C                  (48'b0),

        .D                  (25'b0),

        .ACIN               (30'b0),

        .BCIN               (18'b0),

        .PCIN               (48'b0),

        .CARRYCASCIN        (1'b0),

        .MULTSIGNIN         (1'b0),

        .INMODE             (5'b00000),

        .ALUMODE            (4'b0000),

        .OPMODE             (7'b0000101),

        .CARRYINSEL         (3'b000),

        .CARRYIN            (1'b0),

        .CEA1               (1'b1),

        .CEA2               (1'b1),

        .CEB1               (1'b1),

        .CEB2               (1'b1),

        .CEM                (1'b1),

        .CEP                (1'b1),

        .CEAD               (1'b0),

        .CEALUMODE          (1'b0),

        .CEC                (1'b0),

        .CECARRYIN          (1'b0),

        .CECTRL             (1'b0),

        .CED                (1'b0),

        .CEINMODE          (1'b0),

        .RSTA               (rst),

        .RSTB               (rst),

        .RSTM               (rst),

        .RSTP               (rst),

        .RSTC               (1'b0),

        .RSTD               (1'b0),

        .RSTALLCARRYIN      (1'b0),

        .RSTALUMODE         (1'b0),

        .RSTCTRL            (1'b0),

        .RSTINMODE          (1'b0),

        .P                  (dsp_p_out),

        .ACOUT              (),

        .BCOUT              (),

        .CARRYCASCOUT       (),

        .CARRYOUT           (),

        .MULTSIGNOUT        (),

        .OVERFLOW           (),

        .PATTERNBDETECT     (),

        .PATTERNDETECT      (),

        .PCOUT              (),

        .UNDERFLOW          ()

    );


    // ========================================================================
    // Seed pipeline
    //
    // Keeps the seed aligned with the DSP P output.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r5;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r6;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r7;

    logic v_r5;
    logic v_r6;
    logic v_r7;


    always_ff @(posedge clk) begin

        if (rst) begin

            seed_r5 <= '0;
            seed_r6 <= '0;
            seed_r7 <= '0;

            v_r5 <= 1'b0;
            v_r6 <= 1'b0;
            v_r7 <= 1'b0;

        end
        else begin

            seed_r5 <= seed_r4;
            seed_r6 <= seed_r5;
            seed_r7 <= seed_r6;

            v_r5 <= v_r4;
            v_r6 <= v_r5;
            v_r7 <= v_r6;

        end

    end


    // ========================================================================
    // P8
    //
    // Decouple DSP output from the fabric adder.
    //
    // Convert DSP product into the Q16.16 interpolation correction:
    //
    //   correction = product >>> 11
    //
    // Bits [42:11] contain the required 32-bit Q16.16 correction.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [47:0] dsp_p_r8;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r8;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r8;


    always_ff @(posedge clk) begin

        if (rst) begin

            dsp_p_r8 <= '0;
            seed_r8  <= '0;
            v_r8     <= 1'b0;

        end
        else begin

            dsp_p_r8 <= dsp_p_out;
            seed_r8  <= seed_r7;

            v_r8 <= v_r7;

        end

    end


    // ========================================================================
    // Convert product to signed Q16.16 correction.
    // ========================================================================

    logic signed [43:0] seed_ext;

    logic signed [43:0] prod_ext;


    assign seed_ext =
        {{12{seed_r8[31]}}, seed_r8};


    assign prod_ext =
        {{12{dsp_p_r8[42]}}, dsp_p_r8[42:11]};


    // ========================================================================
    // P9
    //
    // Chunk 0: bits [10:0]
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c0_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c1_seed_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c1_prod_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_seed_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_prod_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [10:0] c3_seed_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [10:0] c3_prod_r9;

    logic v_r9;


    always_ff @(posedge clk) begin

        if (rst) begin

            sum_c0_r9   <= '0;
            carry_c0_r9 <= 1'b0;

            c1_seed_r9  <= '0;
            c1_prod_r9  <= '0;

            c2_seed_r9  <= '0;
            c2_prod_r9  <= '0;

            c3_seed_r9  <= '0;
            c3_prod_r9  <= '0;

            v_r9 <= 1'b0;

        end
        else begin

            {carry_c0_r9, sum_c0_r9} <=
                {1'b0, seed_ext[10:0]} +
                {1'b0, prod_ext[10:0]};

            c1_seed_r9 <= seed_ext[21:11];
            c1_prod_r9 <= prod_ext[21:11];

            c2_seed_r9 <= seed_ext[32:22];
            c2_prod_r9 <= prod_ext[32:22];

            c3_seed_r9 <= seed_ext[43:33];
            c3_prod_r9 <= prod_ext[43:33];

            v_r9 <= v_r8;

        end

    end


    // ========================================================================
    // P10
    //
    // Chunk 1.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c1_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_seed_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_prod_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r10;

    logic v_r10;


    always_ff @(posedge clk) begin

        if (rst) begin

            sum_c1_r10   <= '0;
            carry_c1_r10 <= 1'b0;

            sum_c0_r10 <= '0;

            c2_seed_r10 <= '0;
            c2_prod_r10 <= '0;

            c3_seed_r10 <= '0;
            c3_prod_r10 <= '0;

            v_r10 <= 1'b0;

        end
        else begin

            {carry_c1_r10, sum_c1_r10} <=
                {1'b0, c1_seed_r9} +
                {1'b0, c1_prod_r9} +
                {11'b0, carry_c0_r9};

            sum_c0_r10 <= sum_c0_r9;

            c2_seed_r10 <= c2_seed_r9;
            c2_prod_r10 <= c2_prod_r9;

            c3_seed_r10 <= c3_seed_r9;
            c3_prod_r10 <= c3_prod_r9;

            v_r10 <= v_r9;

        end

    end


    // ========================================================================
    // P11
    //
    // Chunk 2.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c2_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c2_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r11;

    logic v_r11;


    always_ff @(posedge clk) begin

        if (rst) begin

            sum_c2_r11   <= '0;
            carry_c2_r11 <= 1'b0;

            sum_c0_r11 <= '0;
            sum_c1_r11 <= '0;

            c3_seed_r11 <= '0;
            c3_prod_r11 <= '0;

            v_r11 <= 1'b0;

        end
        else begin

            {carry_c2_r11, sum_c2_r11} <=
                {1'b0, c2_seed_r10} +
                {1'b0, c2_prod_r10} +
                {11'b0, carry_c1_r10};

            sum_c0_r11 <= sum_c0_r10;
            sum_c1_r11 <= sum_c1_r10;

            c3_seed_r11 <= c3_seed_r10;
            c3_prod_r11 <= c3_prod_r10;

            v_r11 <= v_r10;

        end

    end


    // ========================================================================
    // P12
    //
    // Chunk 3.
    //
    // One additional guard bit is retained for saturation detection.
    // ========================================================================

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [11:0] sum_c3_r12;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r12;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r12;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c2_r12;

    logic v_r12;


    always_ff @(posedge clk) begin

        if (rst) begin

            sum_c3_r12 <= '0;

            sum_c0_r12 <= '0;
            sum_c1_r12 <= '0;
            sum_c2_r12 <= '0;

            v_r12 <= 1'b0;

        end
        else begin

            sum_c3_r12 <=
                $signed({c3_seed_r11[10], c3_seed_r11}) +
                $signed({c3_prod_r11[10], c3_prod_r11}) +
                $signed({11'b0, carry_c2_r11});

            sum_c0_r12 <= sum_c0_r11;
            sum_c1_r12 <= sum_c1_r11;
            sum_c2_r12 <= sum_c2_r11;

            v_r12 <= v_r11;

        end

    end


    // ========================================================================
    // P13
    //
    // Reconstruct complete signed result and detect overflow.
    // ========================================================================

    logic signed [43:0] sum_full_r12;


    assign sum_full_r12 =
        {
            sum_c3_r12,
            sum_c2_r12,
            sum_c1_r12,
            sum_c0_r12
        };


    logic ovf_pos_r13;

    logic ovf_neg_r13;

    logic [31:0] sum_lo_r13;

    logic v_r13;


    always_ff @(posedge clk) begin

        if (rst) begin

            ovf_pos_r13 <= 1'b0;
            ovf_neg_r13 <= 1'b0;

            sum_lo_r13 <= '0;

            v_r13 <= 1'b0;

        end
        else begin

            ovf_pos_r13 <=
                (sum_full_r12 > 44'sd2147483647);

            ovf_neg_r13 <=
                (sum_full_r12 < -44'sd2147483648);

            sum_lo_r13 <=
                sum_full_r12[31:0];

            v_r13 <= v_r12;

        end

    end


    // ========================================================================
    // P14
    //
    // Final saturation.
    // ========================================================================

    logic [31:0] recip_r14;

    logic v_r14;


    always_ff @(posedge clk) begin

        if (rst) begin

            recip_r14 <= '0;
            v_r14     <= 1'b0;

        end
        else begin

            if (ovf_pos_r13) begin

                recip_r14 <= 32'h7FFF_FFFF;

            end
            else if (ovf_neg_r13) begin

                recip_r14 <= 32'h8000_0000;

            end
            else begin

                recip_r14 <= sum_lo_r13;

            end

            v_r14 <= v_r13;

        end

    end


    // ========================================================================
    // Outputs
    // ========================================================================

    assign recip_out = recip_r14;

    assign valid_out = v_r14;


endmodule