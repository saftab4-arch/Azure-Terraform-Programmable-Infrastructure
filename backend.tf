
terraform {
  backend "azurerm" {

    resource_group_name  = "1-46cd005b-playground-sandbox"
    storage_account_name = "syedlab3tfstate"
    container_name       = "lab3"
    key                  = "terraform.tfstate"

  }

}
