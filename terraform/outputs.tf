output "public_ip" {
  value = azurerm_public_ip.lab.ip_address
}

output "ssh_command" {
  value = "ssh azureuser@${azurerm_public_ip.lab.ip_address}"
}