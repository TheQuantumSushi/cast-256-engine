-- AXI4-Lite write channel (AW + W + B) and register bank.
-- Owns all writable registers; exposes them combinatorially to the read channel
-- via tag_out/mode_out, and to the datapath via the remaining _out ports.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.axi_slave_pkg.all;

entity axi_slave_wr is
    port (
        aclk : in std_ulogic;
        aresetn : in std_ulogic;

        -- AW channel
        s0_axi_awaddr : in std_ulogic_vector(11 downto 0);
        s0_axi_awvalid : in std_ulogic;
        s0_axi_awready : out std_ulogic;

        -- W channel
        s0_axi_wdata : in std_ulogic_vector(31 downto 0);
        s0_axi_wstrb : in std_ulogic_vector(3 downto 0);
        s0_axi_wvalid : in std_ulogic;
        s0_axi_wready : out std_ulogic;

        -- B channel
        s0_axi_bresp : out std_ulogic_vector(1 downto 0);
        s0_axi_bvalid : out std_ulogic;
        s0_axi_bready : in std_ulogic;

        -- Datapath inputs
        csr_busy : in std_ulogic;
        csr_done : in std_ulogic;
        tag_computed_in : in std_ulogic_vector(127 downto 0);

        -- Register outputs to datapath
        key_out : out std_ulogic_vector(255 downto 0);
        iv_out : out std_ulogic_vector(95 downto 0);
        aad_addr_out : out std_ulogic_vector(31 downto 0);
        aad_len_out : out std_ulogic_vector(31 downto 0);
        pt_addr_out : out std_ulogic_vector(31 downto 0);
        pt_len_out : out std_ulogic_vector(31 downto 0);
        ct_addr_out : out std_ulogic_vector(31 downto 0);

        -- Shared with read channel
        tag_out : out std_ulogic_vector(127 downto 0);
        mode_out : out std_ulogic;

        -- Control pulses
        start_out : out std_ulogic;
        soft_reset_out : out std_ulogic;
        key_loaded_out : out std_ulogic
    );
end entity axi_slave_wr;

architecture rtl of axi_slave_wr is

    signal key_r : std_ulogic_vector(255 downto 0) := (others => '0');
    signal iv_r : std_ulogic_vector(95 downto 0) := (others => '0');
    signal aad_addr_r : std_ulogic_vector(31 downto 0) := (others => '0');
    signal aad_len_r : std_ulogic_vector(31 downto 0) := (others => '0');
    signal pt_addr_r : std_ulogic_vector(31 downto 0) := (others => '0');
    signal pt_len_r : std_ulogic_vector(31 downto 0) := (others => '0');
    signal ct_addr_r : std_ulogic_vector(31 downto 0) := (others => '0');
    signal tag_r : std_ulogic_vector(127 downto 0) := (others => '0');
    signal mode_r : std_ulogic := '0';

    -- Bitmask of key words written; pulse key_loaded when all 8 are set
    signal key_word_written : std_ulogic_vector(7 downto 0) := (others => '0');

    signal wr_state : wr_state_t := WR_IDLE;
    signal wr_addr_lat : std_ulogic_vector(11 downto 0) := (others => '0');
    signal wr_data_lat : std_ulogic_vector(31 downto 0) := (others => '0');
    signal wr_strb_lat : std_ulogic_vector(3 downto 0) := (others => '0');

    signal awready_i : std_ulogic := '0';
    signal wready_i : std_ulogic := '0';
    signal bvalid_i : std_ulogic := '0';
    signal bresp_i : std_ulogic_vector(1 downto 0) := RESP_OKAY;

    signal key_loaded_r : std_ulogic := '0';
    signal start_r : std_ulogic := '0';
    signal sreset_r : std_ulogic := '0';

begin

    s0_axi_awready <= awready_i;
    s0_axi_wready <= wready_i;
    s0_axi_bvalid <= bvalid_i;
    s0_axi_bresp <= bresp_i;

    key_out <= key_r;
    iv_out <= iv_r;
    aad_addr_out <= aad_addr_r;
    aad_len_out <= aad_len_r;
    pt_addr_out <= pt_addr_r;
    pt_len_out <= pt_len_r;
    ct_addr_out <= ct_addr_r;
    tag_out <= tag_r;
    mode_out <= mode_r;
    start_out <= start_r;
    soft_reset_out <= sreset_r;
    key_loaded_out <= key_loaded_r;

    ---------------------------------------------------------------------------
    -- Write sub-FSM (AW + W + B channels)
    ---------------------------------------------------------------------------
    p_write : process(aclk)
        variable addr_v : std_ulogic_vector(11 downto 0);
        variable data_v : std_ulogic_vector(31 downto 0);
        variable strb_v : std_ulogic_vector(3 downto 0);
        variable widx : integer;
        variable wr_decerr_v : std_ulogic;
        variable wr_slverr_v : std_ulogic;
    begin
        if rising_edge(aclk) then
            -- Default: clear one-cycle pulses
            start_r <= '0';
            sreset_r <= '0';
            key_loaded_r <= '0';

            if aresetn = '0' then
                wr_state <= WR_IDLE;
                awready_i <= '0';
                wready_i <= '0';
                bvalid_i <= '0';
                bresp_i <= RESP_OKAY;
                key_r <= (others => '0');
                iv_r <= (others => '0');
                aad_addr_r <= (others => '0');
                aad_len_r <= (others => '0');
                pt_addr_r <= (others => '0');
                pt_len_r <= (others => '0');
                ct_addr_r <= (others => '0');
                tag_r <= (others => '0');
                mode_r <= '0';
                key_word_written <= (others => '0');
            else
                case wr_state is

                    when WR_IDLE =>
                        awready_i <= '0';
                        wready_i <= '0';
                        if s0_axi_awvalid = '1' and s0_axi_wvalid = '1' then
                            wr_addr_lat <= s0_axi_awaddr;
                            wr_data_lat <= s0_axi_wdata;
                            wr_strb_lat <= s0_axi_wstrb;
                            awready_i <= '1';
                            wready_i <= '1';
                            wr_state <= WR_BOTH;
                        elsif s0_axi_awvalid = '1' then
                            wr_addr_lat <= s0_axi_awaddr;
                            awready_i <= '1';
                            wr_state <= WR_HAVE_ADDR;
                        elsif s0_axi_wvalid = '1' then
                            wr_data_lat <= s0_axi_wdata;
                            wr_strb_lat <= s0_axi_wstrb;
                            wready_i <= '1';
                            wr_state <= WR_HAVE_DATA;
                        end if;

                    when WR_HAVE_ADDR =>
                        awready_i <= '0';
                        if s0_axi_wvalid = '1' then
                            wr_data_lat <= s0_axi_wdata;
                            wr_strb_lat <= s0_axi_wstrb;
                            wready_i <= '1';
                            wr_state <= WR_BOTH;
                        end if;

                    when WR_HAVE_DATA =>
                        wready_i <= '0';
                        if s0_axi_awvalid = '1' then
                            wr_addr_lat <= s0_axi_awaddr;
                            awready_i <= '1';
                            wr_state <= WR_BOTH;
                        end if;

                    when WR_BOTH =>
                        awready_i <= '0';
                        wready_i <= '0';
                        addr_v := wr_addr_lat;
                        data_v := wr_data_lat;
                        strb_v := wr_strb_lat;

                        wr_decerr_v := '0';
                        wr_slverr_v := '0';
                        widx := to_integer(unsigned(addr_v(4 downto 2)));

                        if addr_v(11 downto 5) = "0000000" and
                           unsigned(addr_v(4 downto 2)) <= 7 then
                            -- 0x000-0x01C: key words 0-7
                            if csr_busy = '0' then
                                for i in 0 to 3 loop
                                    if strb_v(i) = '1' then
                                        key_r(255 - widx*32 - (3-i)*8 downto
                                              255 - widx*32 - (3-i)*8 - 7)
                                            <= data_v(8*(i+1)-1 downto 8*i);
                                    end if;
                                end loop;
                                key_word_written(widx) <= '1';
                                if widx = 7 then
                                    if (key_word_written(6 downto 0) = "1111111") then
                                        key_loaded_r <= '1';
                                    end if;
                                end if;
                            end if;

                        elsif addr_v(11 downto 4) = "00000010" and
                              unsigned(addr_v(3 downto 2)) <= 2 then
                            -- 0x020-0x028: IV words 0-2
                            if csr_busy = '0' then
                                case addr_v(3 downto 2) is
                                    when "00" =>
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                iv_r(95 - (3-i)*8 downto 95 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when "01" =>
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                iv_r(63 - (3-i)*8 downto 63 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when "10" =>
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                iv_r(31 - (3-i)*8 downto 31 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when others => null;
                                end case;
                            end if;

                        elsif addr_v = x"02C" then
                            -- Reserved gap -- DECERR
                            wr_decerr_v := '1';

                        elsif addr_v = x"030" then
                            -- AAD_ADDR: bits [31:30] must be 0 (30-bit DMA address space)
                            if data_v(31 downto 30) /= "00" then
                                wr_slverr_v := '1';
                            elsif csr_busy = '0' then
                                for i in 0 to 3 loop
                                    if strb_v(i) = '1' then
                                        aad_addr_r(8*(i+1)-1 downto 8*i) <= data_v(8*(i+1)-1 downto 8*i);
                                    end if;
                                end loop;
                            end if;

                        elsif addr_v = x"034" then
                            -- AAD_LEN: bits [31:30] must be 0 (max 1 GB)
                            if data_v(31 downto 30) /= "00" then
                                wr_slverr_v := '1';
                            elsif csr_busy = '0' then
                                for i in 0 to 3 loop
                                    if strb_v(i) = '1' then
                                        aad_len_r(8*(i+1)-1 downto 8*i) <= data_v(8*(i+1)-1 downto 8*i);
                                    end if;
                                end loop;
                            end if;

                        elsif addr_v = x"038" then
                            -- PT_ADDR: bits [31:30] must be 0 (30-bit DMA address space)
                            if data_v(31 downto 30) /= "00" then
                                wr_slverr_v := '1';
                            elsif csr_busy = '0' then
                                for i in 0 to 3 loop
                                    if strb_v(i) = '1' then
                                        pt_addr_r(8*(i+1)-1 downto 8*i) <= data_v(8*(i+1)-1 downto 8*i);
                                    end if;
                                end loop;
                            end if;

                        elsif addr_v = x"03C" then
                            -- PT_LEN: bits [31:30] must be 0 (max 1 GB)
                            if data_v(31 downto 30) /= "00" then
                                wr_slverr_v := '1';
                            elsif csr_busy = '0' then
                                for i in 0 to 3 loop
                                    if strb_v(i) = '1' then
                                        pt_len_r(8*(i+1)-1 downto 8*i) <= data_v(8*(i+1)-1 downto 8*i);
                                    end if;
                                end loop;
                            end if;

                        elsif addr_v = x"040" then
                            -- CT_ADDR: bits [31:30] must be 0 (30-bit DMA address space)
                            if data_v(31 downto 30) /= "00" then
                                wr_slverr_v := '1';
                            elsif csr_busy = '0' then
                                for i in 0 to 3 loop
                                    if strb_v(i) = '1' then
                                        ct_addr_r(8*(i+1)-1 downto 8*i) <= data_v(8*(i+1)-1 downto 8*i);
                                    end if;
                                end loop;
                            end if;

                        elsif addr_v = x"044" then
                            -- CT length: read-only, writes ignored
                            null;

                        elsif addr_v(11 downto 5) = "0000010" and
                              unsigned(addr_v(4 downto 2)) >= 2 and
                              unsigned(addr_v(4 downto 2)) <= 5 then
                            -- 0x048-0x054: Tag register (R/W -- expected tag for decrypt)
                            if csr_busy = '0' then
                                case addr_v(4 downto 2) is
                                    when "010" =>  -- 0x048: bits 127:96
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                tag_r(127 - (3-i)*8 downto 127 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when "011" =>  -- 0x04C: bits 95:64
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                tag_r(95 - (3-i)*8 downto 95 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when "100" =>  -- 0x050: bits 63:32
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                tag_r(63 - (3-i)*8 downto 63 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when "101" =>  -- 0x054: bits 31:0
                                        for i in 0 to 3 loop
                                            if strb_v(i) = '1' then
                                                tag_r(31 - (3-i)*8 downto 31 - (3-i)*8 - 7)
                                                    <= data_v(8*(i+1)-1 downto 8*i);
                                            end if;
                                        end loop;
                                    when others => null;
                                end case;
                            end if;

                        elsif addr_v = x"058" then
                            -- CSR: SOFT_RESET effective even when BUSY
                            if strb_v(0) = '1' then
                                if data_v(1) = '1' then
                                    sreset_r <= '1';
                                    key_word_written <= (others => '0');
                                end if;
                                if data_v(0) = '1' and csr_busy = '0' then
                                    start_r <= '1';
                                end if;
                            end if;
                            if strb_v(0) = '1' and csr_busy = '0' then
                                mode_r <= data_v(2);
                            end if;

                        elsif addr_v = x"05C" then
                            -- Debug register: read-only, writes silently ignored
                            null;

                        else
                            wr_decerr_v := '1';
                        end if;

                        if wr_decerr_v = '1' then
                            bresp_i <= RESP_DECERR;
                        elsif wr_slverr_v = '1' then
                            bresp_i <= RESP_SLVERR;
                        else
                            bresp_i <= RESP_OKAY;
                        end if;
                        bvalid_i <= '1';
                        wr_state <= WR_IDLE;

                    when others =>
                        wr_state <= WR_IDLE;
                end case;

                -- Hold BVALID until BREADY
                if bvalid_i = '1' and s0_axi_bready = '1' then
                    bvalid_i <= '0';
                    wr_state <= WR_IDLE;
                end if;

                -- Hardware updates tag from computed value after encryption done
                if csr_done = '1' and mode_r = '0' then
                    tag_r <= tag_computed_in;
                end if;

                -- SOFT_RESET clears all registers
                if sreset_r = '1' then
                    key_r <= (others => '0');
                    iv_r <= (others => '0');
                    aad_addr_r <= (others => '0');
                    aad_len_r <= (others => '0');
                    pt_addr_r <= (others => '0');
                    pt_len_r <= (others => '0');
                    ct_addr_r <= (others => '0');
                    tag_r <= (others => '0');
                    mode_r <= '0';
                    key_word_written <= (others => '0');
                end if;

            end if;
        end if;
    end process p_write;

end architecture rtl;
