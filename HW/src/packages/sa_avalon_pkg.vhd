-- Package: sa_avalon_pkg
--
-- Constants, register map offsets, FSM state types, and bit positions
-- for the Avalon-MM/ST systolic array IP wrapper.

library ieee;
use ieee.std_logic_1164.all;

package sa_avalon_pkg is

    -- Array parameters (must match systolic_array generics)
    constant SA_N          : natural := 4;
    constant SA_DATA_WIDTH : natural := 8;
    constant SA_ACC_WIDTH  : natural := 32;

    -- Derived
    constant SA_A_IN_WIDTH      : natural := SA_N * SA_DATA_WIDTH;   -- 32
    constant SA_RESULT_WIDTH    : natural := SA_N * SA_N * SA_ACC_WIDTH; -- 512
    constant SA_WORDS_PER_MAT   : natural := SA_N;                   -- 4 words/matrix
    constant SA_WORDS_PER_TXN   : natural := 2 * SA_N;              -- 8 words (A+B)
    constant SA_RESULT_WORDS    : natural := SA_N * SA_N;            -- 16 words
    constant SA_FEED_CYCLES     : natural := 2 * SA_N - 1;          -- 7
    constant SA_FLUSH_CYCLES    : natural := 7; -- Increased to let PE(N-1,N-1) finish its last MAC            -- 5

    -- Register word addresses (byte offset / 4)
    constant REG_CTRL        : natural := 0;   -- 0x00  W     Control
    constant REG_STATUS      : natural := 1;   -- 0x04  R/W1C Status
    constant REG_CONFIG      : natural := 2;   -- 0x08  RW    Configuration
    constant REG_PERF_CYCLES : natural := 3;   -- 0x0C  R     Cycle counter
    constant REG_TXN_COUNT   : natural := 4;   -- 0x10  R     Transaction counter
    constant REG_ERR_COUNT   : natural := 5;   -- 0x14  R     Error counter
    constant REG_FIFO_STATUS : natural := 6;   -- 0x18  R     FIFO levels
    -- 7 reserved (0x1C)
    constant REG_VERSION     : natural := 8;   -- 0x20  R     Version
    constant REG_CAPABILITY  : natural := 9;   -- 0x24  R     Array params

    constant CSR_ADDR_WIDTH  : natural := 4;   -- 0..9 = 4 bits

    -- CTRL bit positions (0x00, write-only, self-clearing pulses)
    constant CTRL_START_BIT      : natural := 0;
    constant CTRL_SOFT_RST_BIT   : natural := 1;
    constant CTRL_FLUSH_OUT_BIT  : natural := 2;

    -- STATUS bit positions (0x04, read / write-1-to-clear)
    constant STS_BUSY_BIT            : natural := 0;
    constant STS_DONE_BIT            : natural := 1;
    constant STS_IRQ_PENDING_BIT     : natural := 2;
    constant STS_IN_FIFO_READY_BIT   : natural := 3;
    constant STS_OUT_FIFO_EMPTY_BIT  : natural := 4;
    constant STS_OUT_FIFO_FULL_BIT   : natural := 5;
    constant STS_ERR_OVERFLOW_BIT    : natural := 6;

    -- CONFIG bit positions (0x08, read-write persistent)
    constant CFG_SIGNED_MODE_BIT : natural := 0;   -- read-only (from generic)
    constant CFG_IRQ_EN_BIT      : natural := 1;
    constant CFG_IRQ_ON_EACH_BIT : natural := 2;
    constant CFG_CONTINUOUS_BIT  : natural := 3;

    -- IP version
    constant IP_VER_MAJOR : natural := 1;
    constant IP_VER_MINOR : natural := 0;
    constant IP_VER_PATCH : natural := 0;

    -- FSM state type
    type sa_fsm_state_t is (
        S_IDLE,
        S_LOAD_A,
        S_LOAD_B,
        S_RESET_PE,
        S_COMPUTE,
        S_FLUSH,
        S_CAPTURE,
        S_DONE
    );

end package sa_avalon_pkg;


