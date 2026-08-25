library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sa_avalon_pkg.all;

entity sa_avalon_top is
    generic (
        SIGNED_ARITH    : boolean := true;   -- INT8 signed for quantized NN
        IN_FIFO_DEPTH   : natural := 32;     -- 4 transactions (8 words each)
        OUT_FIFO_DEPTH  : natural := 64      -- 4 transactions (16 words each)
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Avalon-MM CSR slave (word-addressed, read latency = 1)
        avs_address     : in  std_logic_vector(CSR_ADDR_WIDTH - 1 downto 0);
        avs_read        : in  std_logic;
        avs_readdata    : out std_logic_vector(31 downto 0);
        avs_write       : in  std_logic;
        avs_writedata   : in  std_logic_vector(31 downto 0);

        -- Avalon-ST sink (DMA writes packed A+B matrices here)
        asi_data        : in  std_logic_vector(31 downto 0);
        asi_valid       : in  std_logic;
        asi_ready       : out std_logic;

        -- Avalon-ST source (DMA reads C result matrix from here)
        aso_data        : out std_logic_vector(31 downto 0);
        aso_valid       : out std_logic;
        aso_ready       : in  std_logic;

        -- Interrupt request
        irq             : out std_logic
    );
end entity sa_avalon_top;

architecture structural of sa_avalon_top is

    -- Reset Release IP: holds design in reset until FPGA enters user mode
    component reset_release is
        port (
            ninit_done : out std_logic
        );
    end component reset_release;

    signal ninit_done  : std_logic;
    signal rst_n_safe  : std_logic;  -- gated: device ready AND external reset released

    -- CSR ↔ FSM control/status signals
    signal ctrl_start        : std_logic;
    signal ctrl_soft_rst     : std_logic;
    signal ctrl_flush_out    : std_logic;
    signal cfg_irq_en        : std_logic;
    signal cfg_irq_on_each   : std_logic;
    signal cfg_continuous    : std_logic;
    signal sts_busy          : std_logic;
    signal sts_done          : std_logic;
    signal sts_in_fifo_ready : std_logic;
    signal sts_out_fifo_empty : std_logic;
    signal sts_out_fifo_full  : std_logic;
    signal sts_err_overflow   : std_logic;
    signal done_pulse        : std_logic;
    signal perf_cycles       : std_logic_vector(31 downto 0);
    signal txn_count         : std_logic_vector(31 downto 0);
    signal err_count         : std_logic_vector(31 downto 0);

    -- Input FIFO signals
    signal in_fifo_wr_en     : std_logic;
    signal in_fifo_full      : std_logic;
    signal in_fifo_rd_data   : std_logic_vector(31 downto 0);
    signal in_fifo_rd_en     : std_logic;
    signal in_fifo_empty     : std_logic;
    signal in_fifo_level     : std_logic_vector(7 downto 0);
    signal in_fifo_depth_s   : std_logic_vector(7 downto 0);
    signal in_fifo_flush     : std_logic;

    -- Output FIFO signals
    signal out_fifo_wr_data  : std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
    signal out_fifo_wr_en    : std_logic;
    signal out_fifo_full     : std_logic;
    signal out_fifo_rd_data  : std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
    signal out_fifo_rd_en    : std_logic;
    signal out_fifo_empty    : std_logic;
    signal out_fifo_level    : std_logic_vector(7 downto 0);
    signal out_fifo_depth_s  : std_logic_vector(7 downto 0);
    signal out_fifo_flush    : std_logic;

    -- Systolic array signals
    signal sa_rst_n          : std_logic;
    signal sa_compute_en     : std_logic;
    signal sa_a_in           : std_logic_vector(SA_A_IN_WIDTH - 1 downto 0);
    signal sa_b_in           : std_logic_vector(SA_A_IN_WIDTH - 1 downto 0);
    signal sa_a_out          : std_logic_vector(SA_A_IN_WIDTH - 1 downto 0);
    signal sa_b_out          : std_logic_vector(SA_A_IN_WIDTH - 1 downto 0);
    signal sa_result         : std_logic_vector(SA_RESULT_WIDTH - 1 downto 0);

    -- Result capture signals
    signal capture_start     : std_logic;
    signal capture_done      : std_logic;
    signal cap_wr_data       : std_logic_vector(SA_ACC_WIDTH - 1 downto 0);
    signal cap_wr_valid      : std_logic;
    signal cap_wr_ready      : std_logic;

begin

    -- Reset Release: gate all resets until device configuration is complete
    u_reset_release : reset_release
        port map (
            ninit_done => ninit_done
        );

    -- Combine: device-ready AND external reset
    rst_n_safe <= rst_n and (not ninit_done);

    -- Avalon-ST sink → Input FIFO glue
    asi_ready      <= not in_fifo_full;
    in_fifo_wr_en  <= asi_valid and (not in_fifo_full);
    in_fifo_flush  <= ctrl_soft_rst;

    -- Input FIFO has a complete A+B pair when level >= 8 words
    sts_in_fifo_ready <= '1' when unsigned(in_fifo_level) >= SA_WORDS_PER_TXN
                         else '0';

    -- Output FIFO → Avalon-ST source glue
    aso_valid       <= not out_fifo_empty;
    aso_data        <= out_fifo_rd_data;
    out_fifo_rd_en  <= aso_ready and (not out_fifo_empty);
    out_fifo_flush  <= ctrl_flush_out or ctrl_soft_rst;

    -- Status
    sts_done           <= not out_fifo_empty;
    sts_out_fifo_empty <= out_fifo_empty;
    sts_out_fifo_full  <= out_fifo_full;
    sts_err_overflow   <= '0';   -- back-pressure prevents overflow

    -- Result capture → Output FIFO
    out_fifo_wr_data <= cap_wr_data;
    out_fifo_wr_en   <= cap_wr_valid;
    cap_wr_ready     <= not out_fifo_full;

    -- CSR: Avalon-MM register slave
    u_csr : entity work.sa_csr
        generic map (
            SIGNED_ARITH => SIGNED_ARITH
        )
        port map (
            clk              => clk,
            rst_n            => rst_n_safe,
            avs_address      => avs_address,
            avs_read         => avs_read,
            avs_readdata     => avs_readdata,
            avs_write        => avs_write,
            avs_writedata    => avs_writedata,
            ctrl_start       => ctrl_start,
            ctrl_soft_rst    => ctrl_soft_rst,
            ctrl_flush_out   => ctrl_flush_out,
            cfg_irq_en       => cfg_irq_en,
            cfg_irq_on_each  => cfg_irq_on_each,
            cfg_continuous   => cfg_continuous,
            sts_busy         => sts_busy,
            sts_done         => sts_done,
            sts_in_fifo_ready  => sts_in_fifo_ready,
            sts_out_fifo_empty => sts_out_fifo_empty,
            sts_out_fifo_full  => sts_out_fifo_full,
            sts_err_overflow   => sts_err_overflow,
            done_pulse       => done_pulse,
            perf_cycles      => perf_cycles,
            txn_count        => txn_count,
            err_count        => err_count,
            in_fifo_level    => in_fifo_level,
            in_fifo_depth    => in_fifo_depth_s,
            out_fifo_level   => out_fifo_level,
            out_fifo_depth   => out_fifo_depth_s,
            irq              => irq
        );

    -- Input FIFO
    u_in_fifo : entity work.sa_fifo
        generic map (
            WIDTH => 32,
            DEPTH => IN_FIFO_DEPTH
        )
        port map (
            clk       => clk,
            rst_n     => rst_n_safe,
            flush     => in_fifo_flush,
            wr_data   => asi_data,
            wr_en     => in_fifo_wr_en,
            wr_full   => in_fifo_full,
            rd_data   => in_fifo_rd_data,
            rd_en     => in_fifo_rd_en,
            rd_empty  => in_fifo_empty,
            level     => in_fifo_level,
            depth_out => in_fifo_depth_s
        );

    -- Skew FSM: central controller
    u_fsm : entity work.sa_skew_fsm
        port map (
            clk             => clk,
            rst_n           => rst_n_safe,
            start           => ctrl_start,
            soft_rst        => ctrl_soft_rst,
            continuous      => cfg_continuous,
            in_fifo_ready   => sts_in_fifo_ready,
            fifo_rd_data    => in_fifo_rd_data,
            fifo_rd_empty   => in_fifo_empty,
            fifo_rd_en      => in_fifo_rd_en,
            sa_rst_n        => sa_rst_n,
            sa_compute_en   => sa_compute_en,
            sa_a_in         => sa_a_in,
            sa_b_in         => sa_b_in,
            capture_start   => capture_start,
            capture_done    => capture_done,
            busy            => sts_busy,
            done_pulse      => done_pulse,
            perf_cycles     => perf_cycles,
            txn_count       => txn_count,
            err_count       => err_count,
            err_overflow    => sts_err_overflow
        );

    -- Systolic Array (existing design, unchanged)
    u_array : entity work.systolic_array
        generic map (
            N            => SA_N,
            DATA_WIDTH   => SA_DATA_WIDTH,
            ACC_WIDTH    => SA_ACC_WIDTH,
            SIGNED_ARITH => SIGNED_ARITH
        )
        port map (
            clk        => clk,
            rst_n      => sa_rst_n,
            compute_en => sa_compute_en,
            a_in       => sa_a_in,
            b_in       => sa_b_in,
            a_out      => sa_a_out,
            b_out      => sa_b_out,
            result     => sa_result
        );

    -- Result Capture: latch 512-bit result → serialize 16 words to FIFO
    u_capture : entity work.sa_result_capture
        port map (
            clk           => clk,
            rst_n         => rst_n_safe,
            capture_start => capture_start,
            capture_done  => capture_done,
            result        => sa_result,
            wr_data       => cap_wr_data,
            wr_valid      => cap_wr_valid,
            wr_ready      => cap_wr_ready
        );

    -- Output FIFO
    u_out_fifo : entity work.sa_fifo
        generic map (
            WIDTH => SA_ACC_WIDTH,
            DEPTH => OUT_FIFO_DEPTH
        )
        port map (
            clk       => clk,
            rst_n     => rst_n_safe,
            flush     => out_fifo_flush,
            wr_data   => out_fifo_wr_data,
            wr_en     => out_fifo_wr_en,
            wr_full   => out_fifo_full,
            rd_data   => out_fifo_rd_data,
            rd_en     => out_fifo_rd_en,
            rd_empty  => out_fifo_empty,
            level     => out_fifo_level,
            depth_out => out_fifo_depth_s
        );

end architecture structural;