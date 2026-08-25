-- system_top.vhd
-- Top-level wrapper: instantiates the Platform Designer system (sa_avalon)
-- and maps to physical board pins.

library ieee;
use ieee.std_logic_1164.all;

entity system_top is
    port (
        -- Board clock (50 MHz oscillator)
        CLOCK_50    : in  std_logic;

        -- Board reset push-button (active-low on most boards)
        RESET_N     : in  std_logic;

        -- IRQ indicators (active-high, directly active-high from IRQ to LEDs)
        LED_IRQ     : out std_logic;
        LED_DMA0    : out std_logic;
        LED_DMA1    : out std_logic;
        
        -- Reset indicator
        LED_RESET   : out std_logic
    );
end entity system_top;

architecture rtl of system_top is

    -- Platform Designer system component declaration
    component sa_avalon is
        port (
            clk_clk      : in  std_logic := 'X'; -- clk
            dma0_irq_irq : out std_logic;         -- irq
            dma1_irq_irq : out std_logic;         -- irq
            reset_reset  : in  std_logic := 'X';  -- reset (active-high)
            irq_irq      : out std_logic           -- irq
        );
    end component sa_avalon;

    signal not_reset : std_logic;

    -- Raw IRQ signals from Platform Designer system
    signal sa_irq    : std_logic;
    signal dma0_irq  : std_logic;
    signal dma1_irq  : std_logic;

begin

    not_reset <= not RESET_N;

    -- LED outputs (active-low: '0' = ON, '1' = OFF)
    -- Invert so LED ON = interrupt/reset IS active
    LED_IRQ   <= not sa_irq;     -- ON when SA interrupt is pending
    LED_DMA0  <= not dma0_irq;   -- ON when input DMA interrupt fires
    LED_DMA1  <= not dma1_irq;   -- ON when output DMA interrupt fires
    LED_RESET <= not not_reset;  -- ON when system is in reset (button pressed)

    -- Platform Designer system instantiation
    u_system : sa_avalon
        port map (
            clk_clk      => CLOCK_50,
            reset_reset  => not_reset,
            irq_irq      => sa_irq,
            dma0_irq_irq => dma0_irq,
            dma1_irq_irq => dma1_irq
        );

end architecture rtl;
