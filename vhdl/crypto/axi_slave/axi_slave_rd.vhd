-- AXI4-Lite read channel (AR + R).
-- Register reads are stateless: tag and mode are fed in from axi_slave_wr.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.axi_slave_pkg.all;

entity axi_slave_rd is
    port (
        aclk : in std_ulogic;
        aresetn : in std_ulogic;

        -- AR channel
        s0_axi_araddr : in std_ulogic_vector(11 downto 0);
        s0_axi_arvalid : in std_ulogic;
        s0_axi_arready : out std_ulogic;

        -- R channel
        s0_axi_rdata : out std_ulogic_vector(31 downto 0);
        s0_axi_rresp : out std_ulogic_vector(1 downto 0);
        s0_axi_rvalid : out std_ulogic;
        s0_axi_rready : in std_ulogic;

        -- Datapath status inputs
        ct_len_in : in std_ulogic_vector(31 downto 0);
        csr_busy : in std_ulogic;
        csr_done : in std_ulogic;
        csr_tag_valid : in std_ulogic;
        csr_error : in std_ulogic;
        fsm_state_in : in std_ulogic_vector(3 downto 0);

        -- Register state from write channel
        tag_in : in std_ulogic_vector(127 downto 0);
        mode_in : in std_ulogic
    );
end entity axi_slave_rd;

architecture rtl of axi_slave_rd is

    signal rd_state : rd_state_t := RD_IDLE;
    signal rd_addr_lat : std_ulogic_vector(11 downto 0) := (others => '0');

    signal arready_i : std_ulogic := '0';
    signal rvalid_i : std_ulogic := '0';
    signal rdata_i : std_ulogic_vector(31 downto 0) := (others => '0');
    signal rresp_i : std_ulogic_vector(1 downto 0) := RESP_OKAY;

begin

    s0_axi_arready <= arready_i;
    s0_axi_rvalid <= rvalid_i;
    s0_axi_rdata <= rdata_i;
    s0_axi_rresp <= rresp_i;

    ---------------------------------------------------------------------------
    -- Read sub-FSM (AR + R channels)
    ---------------------------------------------------------------------------
    p_read : process(aclk)
        variable addr_v : std_ulogic_vector(11 downto 0);
        variable csr_v : std_ulogic_vector(31 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                rd_state <= RD_IDLE;
                arready_i <= '0';
                rvalid_i <= '0';
                rdata_i <= (others => '0');
                rresp_i <= RESP_OKAY;
            else
                case rd_state is

                    when RD_IDLE =>
                        arready_i <= '0';
                        if s0_axi_arvalid = '1' then
                            rd_addr_lat <= s0_axi_araddr;
                            arready_i <= '1';
                            rd_state <= RD_LATCHED;
                        end if;

                    when RD_LATCHED =>
                        arready_i <= '0';
                        addr_v := rd_addr_lat;

                        rresp_i <= RESP_OKAY;
                        rdata_i <= (others => '0');

                        if addr_v(11 downto 5) = "0000000" and
                           unsigned(addr_v(4 downto 2)) <= 7 then
                            -- Key: write-only, return 0
                            rdata_i <= (others => '0');

                        elsif addr_v(11 downto 4) = "00000010" and
                              unsigned(addr_v(3 downto 2)) <= 2 then
                            -- IV: write-only, return 0
                            rdata_i <= (others => '0');

                        elsif addr_v = x"02C" then
                            rresp_i <= RESP_DECERR;
                            rdata_i <= x"DEADBEEF";

                        elsif addr_v = x"030" then rdata_i <= (others => '0');  -- WO
                        elsif addr_v = x"034" then rdata_i <= (others => '0');  -- WO
                        elsif addr_v = x"038" then rdata_i <= (others => '0');  -- WO
                        elsif addr_v = x"03C" then rdata_i <= (others => '0');  -- WO
                        elsif addr_v = x"040" then rdata_i <= (others => '0');  -- WO

                        elsif addr_v = x"044" then
                            rdata_i <= ct_len_in;

                        elsif addr_v(11 downto 5) = "0000010" and
                              unsigned(addr_v(4 downto 2)) >= 2 and
                              unsigned(addr_v(4 downto 2)) <= 5 then
                            -- 0x048-0x054: Tag register
                            case addr_v(4 downto 2) is
                                when "010" => rdata_i <= tag_in(127 downto 96);  -- 0x048
                                when "011" => rdata_i <= tag_in( 95 downto 64);  -- 0x04C
                                when "100" => rdata_i <= tag_in( 63 downto 32);  -- 0x050
                                when "101" => rdata_i <= tag_in( 31 downto  0);  -- 0x054
                                when others => null;
                            end case;

                        elsif addr_v = x"058" then
                            csr_v := (others => '0');
                            csr_v(2) := mode_in;
                            csr_v(8) := csr_busy;
                            csr_v(9) := csr_done;
                            csr_v(10) := csr_tag_valid;
                            csr_v(11) := csr_error;
                            rdata_i <= csr_v;

                        elsif addr_v = x"05C" then
                            rdata_i <= (27 downto 0 => '0') & fsm_state_in;

                        else
                            rresp_i <= RESP_DECERR;
                            rdata_i <= x"DEADBEEF";
                        end if;

                        rvalid_i <= '1';
                        rd_state <= RD_IDLE;

                    when others =>
                        rd_state <= RD_IDLE;
                end case;

                -- Hold RVALID until RREADY
                if rvalid_i = '1' and s0_axi_rready = '1' then
                    rvalid_i <= '0';
                    rd_state <= RD_IDLE;
                end if;

            end if;
        end if;
    end process p_read;

end architecture rtl;
