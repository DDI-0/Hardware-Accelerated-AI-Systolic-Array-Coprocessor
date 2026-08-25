-- Avalon-MM CSR Slave: sa_csr
--
-- Implements the register map for CPU control of the systolic array IP.
-- Read latency = 1 (registered output).
--
-- Registers:
--   0x00 CTRL        (W)     Self-clearing pulses: START, SOFT_RST, FLUSH_OUT
--   0x04 STATUS      (R/W1C) BUSY, DONE, IRQ, FIFO flags, errors
--   0x08 CONFIG      (RW)    SIGNED_MODE(RO), IRQ_EN, IRQ_ON_EACH, CONTINUOUS
--   0x0C PERF_CYCLES (R)     Last computation cycle count
--   0x10 TXN_COUNT   (R)     Completed transactions
--   0x14 ERR_COUNT   (R)     Overflow error count
--   0x18 FIFO_STATUS (R)     Input/output FIFO levels & depths
--   0x20 VERSION     (R)     IP version
--   0x24 CAPABILITY  (R)     Array dimensions

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sa_avalon_pkg.all;

entity sa_csr is
    generic (
        SIGNED_ARITH : boolean := true
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Avalon-MM slave (read latency = 1)
        avs_address     : in  std_logic_vector(CSR_ADDR_WIDTH - 1 downto 0);
        avs_read        : in  std_logic;
        avs_readdata    : out std_logic_vector(31 downto 0);
        avs_write       : in  std_logic;
        avs_writedata   : in  std_logic_vector(31 downto 0);

        -- Control outputs (active-high pulses, 1 clock wide)
        ctrl_start      : out std_logic;
        ctrl_soft_rst   : out std_logic;
        ctrl_flush_out  : out std_logic;

        -- Config outputs (persistent levels)
        cfg_irq_en      : out std_logic;
        cfg_irq_on_each : out std_logic;
        cfg_continuous  : out std_logic;

        -- Status inputs (active-high levels)
        sts_busy          : in  std_logic;
        sts_done          : in  std_logic;
        sts_in_fifo_ready : in  std_logic;
        sts_out_fifo_empty: in  std_logic;
        sts_out_fifo_full : in  std_logic;
        sts_err_overflow  : in  std_logic;
        done_pulse        : in  std_logic;

        -- Performance / diagnostic inputs
        perf_cycles     : in  std_logic_vector(31 downto 0);
        txn_count       : in  std_logic_vector(31 downto 0);
        err_count       : in  std_logic_vector(31 downto 0);
        in_fifo_level   : in  std_logic_vector(7 downto 0);
        in_fifo_depth   : in  std_logic_vector(7 downto 0);
        out_fifo_level  : in  std_logic_vector(7 downto 0);
        out_fifo_depth  : in  std_logic_vector(7 downto 0);

        -- Interrupt output
        irq             : out std_logic
    );
end entity sa_csr;

architecture rtl of sa_csr is

    -- Config register (writable bits)
    signal config_reg    : std_logic_vector(3 downto 0) := (others => '0');

    -- IRQ pending (sticky, W1C)
    signal irq_pending   : std_logic := '0';
    signal err_ovf_sticky : std_logic := '0';

    -- Self-clearing pulse registers
    signal start_r       : std_logic := '0';
    signal soft_rst_r    : std_logic := '0';
    signal flush_out_r   : std_logic := '0';

    -- Edge detection for FIFO empty→non-empty
    signal out_empty_prev : std_logic := '1';

begin

    -- Control pulse outputs
    ctrl_start     <= start_r;
    ctrl_soft_rst  <= soft_rst_r;
    ctrl_flush_out <= flush_out_r;

    -- Config outputs (use _BIT constants to avoid VHDL case-insensitive
    -- collision with port names like cfg_irq_en)
    cfg_irq_en      <= config_reg(CFG_IRQ_EN_BIT);
    cfg_irq_on_each <= config_reg(CFG_IRQ_ON_EACH_BIT);
    cfg_continuous  <= config_reg(CFG_CONTINUOUS_BIT);

    -- IRQ output
    irq <= irq_pending and config_reg(CFG_IRQ_EN_BIT);

    -- Write process
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                config_reg     <= (others => '0');
                irq_pending    <= '0';
                err_ovf_sticky <= '0';
                start_r        <= '0';
                soft_rst_r     <= '0';
                flush_out_r    <= '0';
                out_empty_prev <= '1';
            else
                -- Self-clear pulses every cycle
                start_r     <= '0';
                soft_rst_r  <= '0';
                flush_out_r <= '0';

                -- Track output FIFO empty→non-empty transition
                out_empty_prev <= sts_out_fifo_empty;

                -- Set IRQ based on mode
                if config_reg(CFG_IRQ_ON_EACH_BIT) = '1' then
                    if done_pulse = '1' then
                        irq_pending <= '1';
                    end if;
                else
                    if out_empty_prev = '1' and sts_out_fifo_empty = '0' then
                        irq_pending <= '1';
                    end if;
                end if;

                -- Sticky error
                if sts_err_overflow = '1' then
                    err_ovf_sticky <= '1';
                end if;

                -- Register writes
                if avs_write = '1' then
                    case to_integer(unsigned(avs_address)) is

                        when REG_CTRL =>
                            start_r     <= avs_writedata(CTRL_START_BIT);
                            soft_rst_r  <= avs_writedata(CTRL_SOFT_RST_BIT);
                            flush_out_r <= avs_writedata(CTRL_FLUSH_OUT_BIT);

                        when REG_STATUS =>
                            -- Write-1-to-clear for sticky bits
                            if avs_writedata(STS_IRQ_PENDING_BIT) = '1' then
                                irq_pending <= '0';
                            end if;
                            if avs_writedata(STS_ERR_OVERFLOW_BIT) = '1' then
                                err_ovf_sticky <= '0';
                            end if;

                        when REG_CONFIG =>
                            -- Bit 0 (SIGNED_MODE) is read-only from generic
                            config_reg(CFG_IRQ_EN_BIT)      <= avs_writedata(CFG_IRQ_EN_BIT);
                            config_reg(CFG_IRQ_ON_EACH_BIT) <= avs_writedata(CFG_IRQ_ON_EACH_BIT);
                            config_reg(CFG_CONTINUOUS_BIT)   <= avs_writedata(CFG_CONTINUOUS_BIT);

                        when others =>
                            null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- Read process (registered output = read latency 1)
    process (clk)
        variable status_word : std_logic_vector(31 downto 0);
        variable config_word : std_logic_vector(31 downto 0);
        variable fifo_word   : std_logic_vector(31 downto 0);
        variable ver_word    : std_logic_vector(31 downto 0);
        variable cap_word    : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if avs_read = '1' then
                case to_integer(unsigned(avs_address)) is

                    when REG_CTRL =>
                        avs_readdata <= (others => '0');

                    when REG_STATUS =>
                        status_word := (others => '0');
                        status_word(STS_BUSY_BIT)           := sts_busy;
                        status_word(STS_DONE_BIT)           := sts_done;
                        status_word(STS_IRQ_PENDING_BIT)    := irq_pending;
                        status_word(STS_IN_FIFO_READY_BIT)  := sts_in_fifo_ready;
                        status_word(STS_OUT_FIFO_EMPTY_BIT) := sts_out_fifo_empty;
                        status_word(STS_OUT_FIFO_FULL_BIT)  := sts_out_fifo_full;
                        status_word(STS_ERR_OVERFLOW_BIT)   := err_ovf_sticky;
                        avs_readdata <= status_word;

                    when REG_CONFIG =>
                        config_word := (others => '0');
                        if SIGNED_ARITH then
                            config_word(CFG_SIGNED_MODE_BIT) := '1';
                        else
                            config_word(CFG_SIGNED_MODE_BIT) := '0';
                        end if;
                        config_word(CFG_IRQ_EN_BIT)      := config_reg(CFG_IRQ_EN_BIT);
                        config_word(CFG_IRQ_ON_EACH_BIT) := config_reg(CFG_IRQ_ON_EACH_BIT);
                        config_word(CFG_CONTINUOUS_BIT)   := config_reg(CFG_CONTINUOUS_BIT);
                        avs_readdata <= config_word;

                    when REG_PERF_CYCLES =>
                        avs_readdata <= perf_cycles;

                    when REG_TXN_COUNT =>
                        avs_readdata <= txn_count;

                    when REG_ERR_COUNT =>
                        avs_readdata <= err_count;

                    when REG_FIFO_STATUS =>
                        fifo_word := (others => '0');
                        fifo_word(7  downto  0) := in_fifo_level;
                        fifo_word(15 downto  8) := out_fifo_level;
                        fifo_word(23 downto 16) := in_fifo_depth;
                        fifo_word(31 downto 24) := out_fifo_depth;
                        avs_readdata <= fifo_word;

                    when REG_VERSION =>
                        ver_word := (others => '0');
                        ver_word(31 downto 24) := std_logic_vector(to_unsigned(IP_VER_MAJOR, 8));
                        ver_word(23 downto 16) := std_logic_vector(to_unsigned(IP_VER_MINOR, 8));
                        ver_word(15 downto  0) := std_logic_vector(to_unsigned(IP_VER_PATCH, 16));
                        avs_readdata <= ver_word;

                    when REG_CAPABILITY =>
                        cap_word := (others => '0');
                        cap_word(7  downto  0) := std_logic_vector(to_unsigned(SA_N, 8));
                        cap_word(15 downto  8) := std_logic_vector(to_unsigned(SA_DATA_WIDTH, 8));
                        cap_word(23 downto 16) := std_logic_vector(to_unsigned(SA_ACC_WIDTH, 8));
                        if SIGNED_ARITH then
                            cap_word(24) := '1';
                        end if;
                        avs_readdata <= cap_word;

                    when others =>
                        avs_readdata <= (others => '0');

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
