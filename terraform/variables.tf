variable "yourname" {
  description = "Lowercase, no spaces. Makes resource names unique."
  type        = string
  default     = "fabrizio"
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "vm_size" {
  description = "VM size. B2s is cheapest; some subscriptions block it."
  type        = string
  default     = "Standard_B2s"
}

variable "my_ip" {
  description = "Your public IP address with /32 on the end."
  type        = string
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}