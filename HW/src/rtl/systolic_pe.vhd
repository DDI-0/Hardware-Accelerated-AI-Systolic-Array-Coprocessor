library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity systolic_pe is
    generic (
        DATA_WIDTH   : integer := 8;
        ACC_WIDTH    : integer := 32;
        SIGNED_ARITH : boolean := false
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        compute_en : in  std_logic;

        a_in       : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        b_in       : in  std_logic_vector(DATA_WIDTH-1 downto 0);

        a_out      : out std_logic_vector(DATA_WIDTH-1 downto 0);
        b_out      : out std_logic_vector(DATA_WIDTH-1 downto 0);
        result     : out std_logic_vector(ACC_WIDTH-1 downto 0)
    );
end entity;

architecture behavior of systolic_pe is
    signal a_reg   : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal b_reg   : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal acc_reg : std_logic_vector(ACC_WIDTH-1 downto 0);
begin

    MAC_function: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                a_reg   <= (others => '0');
                b_reg   <= (others => '0');
                acc_reg <= (others => '0');
            elsif compute_en = '1' then
                if SIGNED_ARITH then
                    acc_reg <= std_logic_vector(
                        signed(acc_reg) + resize(signed(a_in) * signed(b_in), ACC_WIDTH));
                else
                    acc_reg <= std_logic_vector(
                        unsigned(acc_reg) + resize(unsigned(a_in) * unsigned(b_in), ACC_WIDTH));
                end if;
                a_reg   <= a_in;
                b_reg   <= b_in;
            end if;
        end if;
    end process;

    a_out  <= a_reg;
    b_out  <= b_reg;
    result <= acc_reg;

end architecture;
