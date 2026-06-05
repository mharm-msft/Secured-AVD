# =============================================================================
# network.tf — VNet, 3 NSGs (Shortpath-aware), 3 subnets, optional hub peering.
# =============================================================================

# -----------------------------------------------------------------------------
# NSG: session hosts. Allows AVD service tag egress + Shortpath rules.
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "hosts" {
  name                = local.names.nsgHosts
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
}

resource "azurerm_network_security_rule" "hosts_allow_avd_egress" {
  name                        = "Allow-AVD-Egress"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.hosts.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "*"
  destination_address_prefix  = "WindowsVirtualDesktop"
  description                 = "AVD service-tag egress for broker/diagnostics/agent"
}

resource "azurerm_network_security_rule" "hosts_allow_shortpath_stun_3478" {
  count                       = contains(["Public", "Both"], var.rdpShortpathMode) ? 1 : 0
  name                        = "Allow-Shortpath-STUN-3478"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.hosts.name
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "3478"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  description                 = "RDP Shortpath public — STUN to Microsoft"
}

resource "azurerm_network_security_rule" "hosts_allow_shortpath_stun_3479" {
  count                       = contains(["Public", "Both"], var.rdpShortpathMode) ? 1 : 0
  name                        = "Allow-Shortpath-STUN-3479"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.hosts.name
  priority                    = 111
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "3479"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  description                 = "RDP Shortpath public — STUN backup port"
}

resource "azurerm_network_security_rule" "hosts_allow_shortpath_udp_3390" {
  count                       = contains(["Managed", "Both"], var.rdpShortpathMode) ? 1 : 0
  name                        = "Allow-Shortpath-Managed-UDP-3390"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.hosts.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "3390"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
  description                 = "RDP Shortpath managed — UDP 3390 from clients via routable network"
}

# -----------------------------------------------------------------------------
# NSG: private endpoints. No inbound rules — PE NIC is the gatekeeper.
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "pe" {
  name                = local.names.nsgPe
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
}

# -----------------------------------------------------------------------------
# NSG: management subnet (optional).
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "mgmt" {
  count               = local.createMgmtSubnet ? 1 : 0
  name                = local.names.nsgMgmt
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
}

# -----------------------------------------------------------------------------
# VNet + subnets
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = local.names.vnet
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.mergedTags
  address_space       = [var.vnetAddressSpace]
  dns_servers         = var.dnsServers
}

resource "azurerm_subnet" "hosts" {
  name                              = "snet-hosts"
  resource_group_name               = azurerm_resource_group.rg.name
  virtual_network_name              = azurerm_virtual_network.vnet.name
  address_prefixes                  = [var.hostsSubnetCidr]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.rg.name
  virtual_network_name              = azurerm_virtual_network.vnet.name
  address_prefixes                  = [var.peSubnetCidr]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "mgmt" {
  count                             = local.createMgmtSubnet ? 1 : 0
  name                              = "snet-mgmt"
  resource_group_name               = azurerm_resource_group.rg.name
  virtual_network_name              = azurerm_virtual_network.vnet.name
  address_prefixes                  = [var.mgmtSubnetCidr]
  private_endpoint_network_policies = "Disabled"
}

# Subnet ↔ NSG associations
resource "azurerm_subnet_network_security_group_association" "hosts" {
  subnet_id                 = azurerm_subnet.hosts.id
  network_security_group_id = azurerm_network_security_group.hosts.id
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  count                     = local.createMgmtSubnet ? 1 : 0
  subnet_id                 = azurerm_subnet.mgmt[0].id
  network_security_group_id = azurerm_network_security_group.mgmt[0].id
}

# -----------------------------------------------------------------------------
# Optional hub peering (bidirectional). hubVnetId must be readable by the
# principal running terraform — it does not need write access on the hub.
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count                        = local.enablePeering ? 1 : 0
  name                         = local.names.peerSpokeToHub
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.vnet.name
  remote_virtual_network_id    = var.hubVnetId
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
