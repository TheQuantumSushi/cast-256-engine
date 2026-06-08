library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package axi_slave_pkg is

    constant RESP_OKAY   : std_ulogic_vector(1 downto 0) := "00";
    constant RESP_SLVERR : std_ulogic_vector(1 downto 0) := "10";
    constant RESP_DECERR : std_ulogic_vector(1 downto 0) := "11";

    type wr_state_t is (WR_IDLE, WR_HAVE_ADDR, WR_HAVE_DATA, WR_BOTH);
    type rd_state_t is (RD_IDLE, RD_LATCHED);

    -- Returns true if addr falls within a valid register region.
    -- 0x000-0x01C: key words 0-7
    -- 0x020-0x028: IV words 0-2
    -- 0x030-0x05C: CSR/data registers
    function is_mapped(addr : std_ulogic_vector(11 downto 0)) return boolean;

end package axi_slave_pkg;

package body axi_slave_pkg is

    function is_mapped(addr : std_ulogic_vector(11 downto 0)) return boolean is
        variable a : integer;
    begin
        a := to_integer(unsigned(addr(11 downto 2)));
        if a >= 0 and a <= 7 then return true; end if;
        if a >= 8 and a <= 10 then return true; end if;
        if a >= 12 and a <= 23 then return true; end if;
        return false;
    end function;

end package body axi_slave_pkg;
