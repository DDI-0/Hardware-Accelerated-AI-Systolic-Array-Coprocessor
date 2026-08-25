library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity systolic_array is
    generic (
        N            : integer := 4;
        DATA_WIDTH   : integer := 8;
        ACC_WIDTH    : integer := 32;
        SIGNED_ARITH : boolean := false
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        compute_en : in  std_logic;
        a_in       : in  std_logic_vector((N * DATA_WIDTH) - 1 downto 0);
        b_in       : in  std_logic_vector((N * DATA_WIDTH) - 1 downto 0);
        a_out      : out std_logic_vector((N * DATA_WIDTH) - 1 downto 0);
        b_out      : out std_logic_vector((N * DATA_WIDTH) - 1 downto 0);
        result     : out std_logic_vector((N * N * ACC_WIDTH) - 1 downto 0)
    );
end entity systolic_array;

architecture rtl of systolic_array is

    type a_bus_row_t is array (0 to N) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    type a_bus_grid_t is array (0 to N - 1) of a_bus_row_t;

    type b_bus_row_t is array (0 to N - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
    type b_bus_grid_t is array (0 to N) of b_bus_row_t;

    signal a_bus : a_bus_grid_t;
    signal b_bus : b_bus_grid_t;

begin

    -- Boundary connections
    gen_boundaries : for i in 0 to N - 1 generate
        a_bus(i)(0) <= a_in((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH);
        a_out((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH) <= a_bus(i)(N);

        b_bus(0)(i) <= b_in((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH);
        b_out((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH) <= b_bus(N)(i);
    end generate gen_boundaries;

    -- PE arrayw
    gen_row : for r in 0 to N - 1 generate
        gen_col : for c in 0 to N - 1 generate
            u_pe : entity work.systolic_pe_wrap
                generic map (
                    DATA_WIDTH   => DATA_WIDTH,
                    ACC_WIDTH    => ACC_WIDTH,
                    SIGNED_ARITH => SIGNED_ARITH
                )
                port map (
                    clk        => clk,
                    rst_n      => rst_n,
                    compute_en => compute_en,
                    a_in       => a_bus(r)(c),
                    b_in       => b_bus(r)(c),
                    a_out      => a_bus(r)(c + 1),
                    b_out      => b_bus(r + 1)(c),
                    result     => result(((r * N + c) + 1) * ACC_WIDTH - 1 downto (r * N + c) * ACC_WIDTH)
                );
        end generate gen_col;
    end generate gen_row;

end architecture rtl;
