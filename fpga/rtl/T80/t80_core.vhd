-- =============================================================================
-- TurboACE: T80pa with plain port names (DO is a Verilog keyword), for the
-- standalone build's Verilog top level and for GHDL's Verilog output in simulation.
-- A Z80 (Mode 0); CEN_p at each T-state's start, CEN_n at its middle.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;

entity t80_core is
    port (
        clk     : in  std_logic;
        reset_n : in  std_logic;
        cen_p   : in  std_logic;
        cen_n   : in  std_logic;
        wait_n  : in  std_logic;
        int_n   : in  std_logic;
        nmi_n   : in  std_logic;
        m1_n    : out std_logic;
        mreq_n  : out std_logic;
        iorq_n  : out std_logic;
        rd_n    : out std_logic;
        wr_n    : out std_logic;
        rfsh_n  : out std_logic;
        halt_n  : out std_logic;
        addr    : out std_logic_vector(15 downto 0);
        din     : in  std_logic_vector(7 downto 0);
        dout    : out std_logic_vector(7 downto 0)
    );
end t80_core;

architecture rtl of t80_core is
begin
    cpu : entity work.T80pa
        generic map (Mode => 0)
        port map (
            RESET_n => reset_n,
            CLK     => clk,
            CEN_p   => cen_p,
            CEN_n   => cen_n,
            WAIT_n  => wait_n,
            INT_n   => int_n,
            NMI_n   => nmi_n,
            BUSRQ_n => '1',
            M1_n    => m1_n,
            MREQ_n  => mreq_n,
            IORQ_n  => iorq_n,
            RD_n    => rd_n,
            WR_n    => wr_n,
            RFSH_n  => rfsh_n,
            HALT_n  => halt_n,
            BUSAK_n => open,
            OUT0    => '0',
            A       => addr,
            DI      => din,
            DO      => dout,
            REG     => open,
            DIRSet  => '0',
            DIR     => (others => '0'),
            HOLD    => '0',
            HELD    => open
        );
end rtl;
