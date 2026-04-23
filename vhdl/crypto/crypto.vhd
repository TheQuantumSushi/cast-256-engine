library ieee;
use ieee.std_logic_1164.all;

entity crypto is
    port(
        aclk:           in  std_ulogic;
        aresetn:        in  std_ulogic;
        s0_axi_araddr:  in  std_ulogic_vector(11 downto 0);
        s0_axi_arvalid: in  std_ulogic;
        s0_axi_arready: out std_ulogic;
        s0_axi_awaddr:  in  std_ulogic_vector(11 downto 0);
        s0_axi_awvalid: in  std_ulogic;
        s0_axi_awready: out std_ulogic;
        s0_axi_wdata:   in  std_ulogic_vector(31 downto 0);
        s0_axi_wstrb:   in  std_ulogic_vector(3 downto 0);
        s0_axi_wvalid:  in  std_ulogic;
        s0_axi_wready:  out std_ulogic;
        s0_axi_rdata:   out std_ulogic_vector(31 downto 0);
        s0_axi_rresp:   out std_ulogic_vector(1 downto 0);
        s0_axi_rvalid:  out std_ulogic;
        s0_axi_rready:  in  std_ulogic;
        s0_axi_bresp:   out std_ulogic_vector(1 downto 0);
        s0_axi_bvalid:  out std_ulogic;
        s0_axi_bready:  in  std_ulogic;
        m0_axi_araddr:  out std_ulogic_vector(29 downto 0);
        m0_axi_arvalid: out std_ulogic;
        m0_axi_arready: in  std_ulogic;
        m0_axi_awaddr:  out std_ulogic_vector(29 downto 0);
        m0_axi_awvalid: out std_ulogic;
        m0_axi_awready: in  std_ulogic;
        m0_axi_wdata:   out std_ulogic_vector(31 downto 0);
        m0_axi_wstrb:   out std_ulogic_vector(3 downto 0);
        m0_axi_wvalid:  out std_ulogic;
        m0_axi_wready:  in  std_ulogic;
        m0_axi_rdata:   in  std_ulogic_vector(31 downto 0);
        m0_axi_rresp:   in  std_ulogic_vector(1 downto 0);
        m0_axi_rvalid:  in  std_ulogic;
        m0_axi_rready:  out std_ulogic;
        m0_axi_bresp:   in  std_ulogic_vector(1 downto 0);
        m0_axi_bvalid:  in  std_ulogic;
        m0_axi_bready:  out std_ulogic;
        irq:            out std_ulogic;
        sw:             in  std_ulogic_vector(3 downto 0);
        btn:            in  std_ulogic_vector(3 downto 0);
        led:            out std_ulogic_vector(3 downto 0)
    );

end entity crypto;

architecture rtl of crypto is
begin
end architecture rtl;

-- vim: set tabstop=4 softtabstop=4 shiftwidth=4 expandtab textwidth=0:
