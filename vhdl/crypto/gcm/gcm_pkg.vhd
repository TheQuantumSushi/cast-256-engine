-- ┌──────────────────────────────────────────────────────────────────┐
-- │ gcm_pkg                                                          │
-- │                                                                  │
-- │ Shared constants and utility functions for the GCM pipeline.     │
-- │ Imported by gf128_mul, ghash, and gcm.                           │
-- │                                                                  │
-- │ Contents :                                                       │
-- │   GF_R   - 128-bit GF(2^128) reduction polynomial                │
-- │   inc32  - increment the rightmost 32 bits of a 128-bit block    │
-- └──────────────────────────────────────────────────────────────────┘

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package gcm_pkg is

    -- ┌─────────────────────────────────┐
    -- │ Constants                       │
    -- └─────────────────────────────────┘

    -- GF(2^128) reduction polynomial: R = 11100001 || 0^120
    -- Corresponds to x^128 + x^7 + x^2 + x + 1 (NIST SP 800-38D §6.3).
    constant GF_R : std_ulogic_vector(127 downto 0) :=
        x"E1000000000000000000000000000000";

    -- ┌─────────────────────────────────┐
    -- │ Functions                       │
    -- └─────────────────────────────────┘

    -- inc32 : increment the rightmost 32 bits of a 128-bit block,
    --         wrapping modulo 2^32. The upper 96 bits are unchanged.
    --         Used to generate GCTR counter blocks (NIST SP 800-38D §6.2).
    function inc32 (blk : std_ulogic_vector(127 downto 0))
        return std_ulogic_vector;

end package gcm_pkg;

package body gcm_pkg is

    function inc32 (blk : std_ulogic_vector(127 downto 0))
        return std_ulogic_vector is
        variable lo : unsigned(31 downto 0);
    begin
        lo := unsigned(blk(31 downto 0)) + 1;
        return blk(127 downto 32) & std_ulogic_vector(lo);
    end function inc32;

end package body gcm_pkg;
