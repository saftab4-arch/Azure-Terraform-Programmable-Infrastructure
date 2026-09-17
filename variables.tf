variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region for Lab 3"
  type        = string
}

variable "subnets" {
  type = map(object({
    address_prefix = string
  }))
}
