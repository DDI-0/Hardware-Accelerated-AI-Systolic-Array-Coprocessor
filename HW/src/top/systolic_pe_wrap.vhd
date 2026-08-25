library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity systolic_pe_wrap is
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
end entity systolic_pe_wrap;

architecture rtl of systolic_pe_wrap is
begin
    u_pe : entity work.systolic_pe
        generic map (
            DATA_WIDTH   => DATA_WIDTH,
            ACC_WIDTH    => ACC_WIDTH,
            SIGNED_ARITH => SIGNED_ARITH
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
end architecture rtl;
