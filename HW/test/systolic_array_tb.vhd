-- Testbench: systolic_array_tb
--
-- Performs a 4x4 matrix multiplication  C = A * B  using the systolic array.
-- Inputs are "skewed" (staggered) so that the correct A-row and B-column
-- elements meet inside each PE at the same clock cycle.
--
-- Skewing rule:
--   Feed A[r][k] at cycle (k + r)      -- row r delayed by r cycles
--   Feed B[k][c] at cycle (k + c)      -- col c delayed by c cycles
--   => both arrive at PE(r,c) at cycle (k + r + c)
--
-- Total feeding window: 2*N - 1 = 7 cycles   (cycles 0..6)
-- Last PE (3,3) finishes accumulating at cycle 3+3+3 = 9

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity systolic_array_tb is
end entity;

architecture sim of systolic_array_tb is

    constant N          : integer := 4;
    constant DATA_WIDTH : integer := 8;
    constant ACC_WIDTH  : integer := 32;
    constant CLK_PERIOD : time    := 10 ns;

    -- DUT signals
    signal clk        : std_logic := '0';
    signal rst_n      : std_logic := '0';
    signal compute_en : std_logic := '0';
    signal a_in       : std_logic_vector(N * DATA_WIDTH - 1 downto 0) := (others => '0');
    signal b_in       : std_logic_vector(N * DATA_WIDTH - 1 downto 0) := (others => '0');
    signal a_out      : std_logic_vector(N * DATA_WIDTH - 1 downto 0);
    signal b_out      : std_logic_vector(N * DATA_WIDTH - 1 downto 0);
    signal result     : std_logic_vector(N * N * ACC_WIDTH - 1 downto 0);

    -- Test matrices  (row-major, flat arrays)
    --   A = [ 1  2  3  4 ]     B = [ 17 18 19 20 ]
    --       [ 5  6  7  8 ]         [ 21 22 23 24 ]
    --       [ 9 10 11 12 ]         [ 25 26 27 28 ]
    --       [13 14 15 16 ]         [ 29 30 31 32 ]
    --
    --   C = A * B
    --     = [ 250  260  270  280 ]
    --       [ 618  644  670  696 ]
    --       [ 986 1028 1070 1112 ]
    --       [1354 1412 1470 1528 ]
    type matrix_t is array (0 to N * N - 1) of integer;

    constant MAT_A : matrix_t := (
         1,  2,  3,  4,
         5,  6,  7,  8,
         9, 10, 11, 12,
        13, 14, 15, 16
    );

    constant MAT_B : matrix_t := (
        17, 18, 19, 20,
        21, 22, 23, 24,
        25, 26, 27, 28,
        29, 30, 31, 32
    );

    constant MAT_C : matrix_t := (
         250,  260,  270,  280,
         618,  644,  670,  696,
         986, 1028, 1070, 1112,
        1354, 1412, 1470, 1528
    );

    -- Stop clock when simulation is done
    signal done : boolean := false;

begin

    -- Clock generator  (stops when 'done' is asserted)
    clk <= not clk after CLK_PERIOD / 2 when not done else '0';

    -- DUT instantiation
    u_dut : entity work.systolic_array
        generic map (
            N          => N,
            DATA_WIDTH => DATA_WIDTH,
            ACC_WIDTH  => ACC_WIDTH
        )
        port map (
            clk        => clk,
            rst_n      => rst_n,
            compute_en => compute_en,
            a_in       => a_in,
            b_in       => b_in,
            a_out      => a_out,
            b_out      => b_out,
            result     => result
        );

    -- Stimulus process
    stim : process
        variable k          : integer;
        variable a_val      : integer;
        variable b_val      : integer;
        variable got        : integer;
        variable exp        : integer;
        variable all_pass   : boolean := true;
    begin
        -- 1. Reset
        rst_n      <= '0';
        compute_en <= '0';
        a_in       <= (others => '0');
        b_in       <= (others => '0');
        wait for CLK_PERIOD * 3;
        wait until rising_edge(clk);
        rst_n <= '1';
        wait until rising_edge(clk);

        -- 2. Feed skewed data for 2*N - 1 = 7 clock cycles
        --
        --    At cycle t, for each row/col index i:
        --      k = t - i
        --      a_in[slice i] = A[i][k]   (if 0 <= k <= N-1, else 0)
        --      b_in[slice i] = B[k][i]   (if 0 <= k <= N-1, else 0)
        compute_en <= '1';

        for t in 0 to 2 * N - 2 loop

            for i in 0 to N - 1 loop
                k := t - i;

                -- A: row i, column k
                if k >= 0 and k <= N - 1 then
                    a_val := MAT_A(i * N + k);
                else
                    a_val := 0;
                end if;
                a_in((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH)
                    <= std_logic_vector(to_unsigned(a_val, DATA_WIDTH));

                -- B: row k, column i
                if k >= 0 and k <= N - 1 then
                    b_val := MAT_B(k * N + i);
                else
                    b_val := 0;
                end if;
                b_in((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH)
                    <= std_logic_vector(to_unsigned(b_val, DATA_WIDTH));
            end loop;

            wait until rising_edge(clk);
        end loop;

        -- 3. Zero inputs, keep compute_en high for pipeline flush
        --    (multiply-by-zero adds nothing to accumulators)
        a_in <= (others => '0');
        b_in <= (others => '0');

        -- Wait N extra cycles so the deepest PE (N-1, N-1) finishes
        for i in 0 to N loop
            wait until rising_edge(clk);
        end loop;

        compute_en <= '0';
        wait until rising_edge(clk);

        -- 4. Check every result element
        report "  Checking C = A * B   (4x4)";

        for r in 0 to N - 1 loop
            for c in 0 to N - 1 loop
                got := to_integer(unsigned(
                    result(((r * N + c) + 1) * ACC_WIDTH - 1
                           downto (r * N + c) * ACC_WIDTH)));
                exp := MAT_C(r * N + c);

                if got /= exp then
                    report "FAIL  C(" & integer'image(r) & ","
                           & integer'image(c) & ") = "
                           & integer'image(got) & "  expected "
                           & integer'image(exp)
                        severity error;
                    all_pass := false;
                else
                    report "PASS  C(" & integer'image(r) & ","
                           & integer'image(c) & ") = "
                           & integer'image(got)
                        severity note;
                end if;
            end loop;
        end loop;

        if all_pass then
            report "  ALL 16 ELEMENTS MATCH -- TEST PASSED";
        else
            report "  SOME ELEMENTS FAILED -- TEST FAILED"
                severity failure;
        end if;

        done <= true;
        wait;
    end process;

end architecture;
