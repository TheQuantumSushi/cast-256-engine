-- AXI4-Lite Slave Interface (s0_axi)
-- Register map: Key(0x000-0x01C), IV(0x020-0x028), AAD addr/len(0x030-0x034),
--               PT addr/len(0x038-0x03C), CT addr/len(0x040-0x044),
--               Tag(0x048-0x054), CSR(0x058), Debug(0x05C)
-- DECERR on all other addresses.
--
-- Structural wrapper: instantiates axi_slave_wr (write channel + register bank)
-- and axi_slave_rd (read channel), wiring tag/mode between them.

library ieee;
use ieee.std_logic_1164.all;

entity axi_slave is
    port (
        aclk : in std_ulogic;
        aresetn : in std_ulogic;

        -- AXI4-Lite write address channel
        s0_axi_awaddr : in std_ulogic_vector(11 downto 0);
        s0_axi_awvalid : in std_ulogic;
        s0_axi_awready : out std_ulogic;

        -- AXI4-Lite write data channel
        s0_axi_wdata : in std_ulogic_vector(31 downto 0);
        s0_axi_wstrb : in std_ulogic_vector(3 downto 0);
        s0_axi_wvalid : in std_ulogic;
        s0_axi_wready : out std_ulogic;

        -- AXI4-Lite write response channel
        s0_axi_bresp : out std_ulogic_vector(1 downto 0);
        s0_axi_bvalid : out std_ulogic;
        s0_axi_bready : in std_ulogic;

        -- AXI4-Lite read address channel
        s0_axi_araddr : in std_ulogic_vector(11 downto 0);
        s0_axi_arvalid : in std_ulogic;
        s0_axi_arready : out std_ulogic;

        -- AXI4-Lite read data channel
        s0_axi_rdata : out std_ulogic_vector(31 downto 0);
        s0_axi_rresp : out std_ulogic_vector(1 downto 0);
        s0_axi_rvalid : out std_ulogic;
        s0_axi_rready : in std_ulogic;

        -- Register outputs to datapath
        key_reg : out std_ulogic_vector(255 downto 0);
        iv_reg : out std_ulogic_vector(95 downto 0);
        aad_addr_reg : out std_ulogic_vector(31 downto 0);
        aad_len_reg : out std_ulogic_vector(31 downto 0);
        pt_addr_reg : out std_ulogic_vector(31 downto 0);
        pt_len_reg : out std_ulogic_vector(31 downto 0);
        ct_addr_reg : out std_ulogic_vector(31 downto 0);
        tag_reg_out : out std_ulogic_vector(127 downto 0);  -- expected tag (decrypt)
        csr_start : out std_ulogic;
        csr_soft_reset : out std_ulogic;
        csr_mode : out std_ulogic;  -- 0=enc, 1=dec

        -- Inputs from datapath
        ct_len_in : in std_ulogic_vector(31 downto 0);
        tag_computed_in : in std_ulogic_vector(127 downto 0);
        csr_busy : in std_ulogic;
        csr_done : in std_ulogic;
        csr_tag_valid : in std_ulogic;
        csr_error : in std_ulogic;
        fsm_state_in : in std_ulogic_vector(3 downto 0);

        -- H precomputation trigger
        key_loaded_pulse : out std_ulogic
    );
end entity axi_slave;

architecture structural of axi_slave is

    -- Internal wires between write and read channels
    signal tag_internal : std_ulogic_vector(127 downto 0);
    signal mode_internal : std_ulogic;

begin

    tag_reg_out <= tag_internal;
    csr_mode <= mode_internal;

    u_wr : entity work.axi_slave_wr
        port map (
            aclk => aclk,
            aresetn => aresetn,
            s0_axi_awaddr => s0_axi_awaddr,
            s0_axi_awvalid => s0_axi_awvalid,
            s0_axi_awready => s0_axi_awready,
            s0_axi_wdata => s0_axi_wdata,
            s0_axi_wstrb => s0_axi_wstrb,
            s0_axi_wvalid => s0_axi_wvalid,
            s0_axi_wready => s0_axi_wready,
            s0_axi_bresp => s0_axi_bresp,
            s0_axi_bvalid => s0_axi_bvalid,
            s0_axi_bready => s0_axi_bready,
            csr_busy => csr_busy,
            csr_done => csr_done,
            tag_computed_in => tag_computed_in,
            key_out => key_reg,
            iv_out => iv_reg,
            aad_addr_out => aad_addr_reg,
            aad_len_out => aad_len_reg,
            pt_addr_out => pt_addr_reg,
            pt_len_out => pt_len_reg,
            ct_addr_out => ct_addr_reg,
            tag_out => tag_internal,
            mode_out => mode_internal,
            start_out => csr_start,
            soft_reset_out => csr_soft_reset,
            key_loaded_out => key_loaded_pulse
        );

    u_rd : entity work.axi_slave_rd
        port map (
            aclk => aclk,
            aresetn => aresetn,
            s0_axi_araddr => s0_axi_araddr,
            s0_axi_arvalid => s0_axi_arvalid,
            s0_axi_arready => s0_axi_arready,
            s0_axi_rdata => s0_axi_rdata,
            s0_axi_rresp => s0_axi_rresp,
            s0_axi_rvalid => s0_axi_rvalid,
            s0_axi_rready => s0_axi_rready,
            ct_len_in => ct_len_in,
            csr_busy => csr_busy,
            csr_done => csr_done,
            csr_tag_valid => csr_tag_valid,
            csr_error => csr_error,
            fsm_state_in => fsm_state_in,
            tag_in => tag_internal,
            mode_in => mode_internal
        );

end architecture structural;
