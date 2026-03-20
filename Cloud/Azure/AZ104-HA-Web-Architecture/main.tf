terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# 1. RESOURCE GROUP & VNET
resource "azurerm_resource_group" "rg" {
  name     = "rg-az104ha-dev-eastus-001"
  location = "eastus"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-az104ha-dev-eastus-001"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "appgw_subnet" {
  name                 = "snet-appgw-001"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "vmss_subnet" {
  name                 = "snet-vmss-001"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# 2. PUBLIC IP FOR APPLICATION GATEWAY
resource "azurerm_public_ip" "appgw_pip" {
  name                = "pip-appgw-001"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 3. APPLICATION GATEWAY (Phase 2 of your lab)
resource "azurerm_application_gateway" "appgw" {
  name                = "agw-az104ha-dev-eastus-001"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "bpool-vmss-001"
  }

  backend_http_settings {
    name                  = "bes-http-80"
    cookie_based_affinity = "Disabled" # Remember we disabled this for the test!
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "listener-http-80"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule-http-80"
    rule_type                  = "Basic"
    http_listener_name         = "listener-http-80"
    backend_address_pool_name  = "bpool-vmss-001"
    backend_http_settings_name = "bes-http-80"
    priority                   = 1
  }
}

# 4. VIRTUAL MACHINE SCALE SET (Phase 3 of your lab)
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                            = "vmss-az104ha-dev-eastus-001"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  sku                             = "Standard_B2s"
  instances                       = 2
  admin_username                  = "azureuser"
  admin_password                  = "PqaLiLn1MUk29O"
  disable_password_authentication = false

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "StandardSSD_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.vmss_subnet.id

      # THIS IS THE MAGIC LINK: Automatically drops new VMs into the App Gateway bucket
      application_gateway_backend_address_pool_ids = [for pool in azurerm_application_gateway.appgw.backend_address_pool : pool.id if pool.name == "bpool-vmss-001"]
    }
  }

  custom_data = base64encode(<<-EOF
      #!/bin/bash
      apt-get update
      apt-get install -y nginx stress
      rm -f /var/www/html/index.nginx-debian.html
      echo "<h1>Hello from Azure VMSS Instance: $(hostname)</h1>" > /var/www/html/index.html
      systemctl restart nginx
    EOF
  )
}

# 5. AUTOSCALING RULES (Phase 5 of your lab)
resource "azurerm_monitor_autoscale_setting" "autoscale" {
  name                = "autoscale-vmss-001"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "defaultProfile"

    capacity {
      default = 2
      minimum = 2
      maximum = 4
    }

    # Scale Out Rule (Above 75% for 5 mins)
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    # Scale In Rule (Below 25% for 5 mins)
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }
}
