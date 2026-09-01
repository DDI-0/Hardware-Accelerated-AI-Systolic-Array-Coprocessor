library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sa_fifo is
    generic (
        WIDTH : integer := 32;
        DEPTH : integer := 64
    );
    port (
        clk   : in std_logic;
        rst_n : in std_logic;
        flush : in std_logic;

        wr_en   : in std_logic;
        wr_data : in std_logic_vector(WIDTH - 1 downto 0);
        wr_full : out std_logic;

        rd_en   : in std_logic;
        rd_data : out std_logic_vector(WIDTH - 1 downto 0);
        rd_empty: out std_logic;

        level     : out std_logic_vector(7 downto 0);
        depth_out : out std_logic_vector(7 downto 0)
    );
end entity sa_fifo;

architecture rtl of sa_fifo is
    type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
    signal mem : mem_t := (others => (others => '0'));
    signal wr_ptr : integer range 0 to DEPTH - 1 := 0;
    signal rd_ptr : integer range 0 to DEPTH - 1 := 0;
    signal count : integer range 0 to DEPTH := 0;
begin

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        elsif rising_edge(clk) then
            if flush = '1' then
                wr_ptr <= 0;
                rd_ptr <= 0;
                count <= 0;
            else
                if wr_en = '1' then
                    mem(wr_ptr) <= wr_data;
                    if wr_ptr = DEPTH - 1 then
                        wr_ptr <= 0;
                    else
                        wr_ptr <= wr_ptr + 1;
                    end if;
                end if;
                
                if rd_en = '1' and count > 0 then
                    if rd_ptr = DEPTH - 1 then
                        rd_ptr <= 0;
                    else
                        rd_ptr <= rd_ptr + 1;
                    end if;
                end if;
                
                if wr_en = '1' and rd_en = '0' then
                    count <= count + 1;
                elsif wr_en = '0' and rd_en = '1' then
                    count <= count - 1;
                end if;
            end if;
        end if;
    end process;

    -- FWFT combinational read (Ring Buffer)
    rd_data   <= mem(rd_ptr);
    rd_empty  <= '1' when count = 0 else '0';
    wr_full   <= '1' when count = DEPTH else '0';
    level     <= std_logic_vector(to_unsigned(count, 8));
    depth_out <= std_logic_vector(to_unsigned(DEPTH, 8));

end architecture rtl;
