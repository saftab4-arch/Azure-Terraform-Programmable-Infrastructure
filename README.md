# Azure Terraform Programmable Infrastructure — Lab 3

A hands-on Azure Terraform lab focused on moving from repetitive resource blocks toward **data-driven and programmable infrastructure**.

This lab builds a small three-tier Azure network using Terraform variables, `map(object)`, `for_each`, resource references, string interpolation, and an Azure Blob remote backend.

The purpose of this lab was not simply to deploy Azure resources. The main objective was to understand how Terraform can use structured data to generate and connect multiple infrastructure resources from reusable code.

---

## Architecture

```text
                    Azure Resource Group
                           │
                           ▼
                    VNet: 10.10.0.0/16
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
         Web Subnet    App Subnet     DB Subnet
        10.10.1.0/24  10.10.2.0/24  10.10.3.0/24
              │            │            │
              ▼            ▼            ▼
           Web NIC       App NIC       DB NIC
              │            │            │
              ▼            ▼            ▼
           Web VM         App VM        DB VM
```

Terraform state is stored separately in Azure Blob Storage:

```text
Terraform
    │
    ▼
Azure Storage Account
    │
    ▼
Blob Container
    │
    ▼
lab3/terraform.tfstate
```

---

# What I Learned

## 1. Terraform Variables

Instead of hardcoding values throughout `main.tf`, variables define the inputs expected by the Terraform configuration.

Example:

```hcl
variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
}

variable "location" {
  description = "Azure region for Lab 3"
  type        = string
}
```

Values are supplied separately through `terraform.tfvars`.

```hcl
resource_group_name = "<resource-group-name>"
location            = "westus"
```

This separates:

```text
variables.tf
     │
     └── Defines WHAT inputs Terraform expects

terraform.tfvars
     │
     └── Supplies the VALUES

main.tf
     │
     └── Consumes those values
```

---

# 2. Terraform `map(object)`

One of the main concepts introduced in this lab was structured Terraform data.

Instead of creating separate variables for every subnet, the subnets are represented as a map.

```hcl
variable "subnets" {
  type = map(object({
    address_prefix = string
  }))
}
```

The corresponding values can look like:

```hcl
subnets = {
  web = {
    address_prefix = "10.10.1.0/24"
  }

  app = {
    address_prefix = "10.10.2.0/24"
  }

  db = {
    address_prefix = "10.10.3.0/24"
  }
}
```

### Mental Model

The **map** provides the named keys:

```text
web
app
db
```

Each key points to an **object**.

```text
web
 │
 └── {
       address_prefix = "10.10.1.0/24"
     }
```

The object defines the structure each map entry must follow.

This allows infrastructure configuration to be represented as structured data instead of duplicated Terraform resource blocks.

---

# 3. `for_each`

The most important programmability concept in this lab was `for_each`.

Instead of writing three subnet resource blocks:

```text
web subnet
app subnet
db subnet
```

Terraform can iterate over the subnet map.

```hcl
resource "azurerm_subnet" "subnets" {
  for_each = var.subnets

  name                 = "${each.key}-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.lab3_vnet.name
  address_prefixes     = [each.value.address_prefix]
}
```

Terraform effectively performs:

```text
Iteration 1
each.key   = web
each.value = web object

Iteration 2
each.key   = app
each.value = app object

Iteration 3
each.key   = db
each.value = db object
```

One Terraform resource block therefore creates:

```text
web-subnet
app-subnet
db-subnet
```

---

# 4. `each.key` and `each.value`

Inside a resource using `for_each`, Terraform exposes the current map entry.

```hcl
each.key
```

represents the map key:

```text
web
app
db
```

While:

```hcl
each.value
```

represents the object associated with that key.

For example:

```hcl
each.value.address_prefix
```

retrieves the address prefix from the current subnet object.

---

# 5. Terraform String Interpolation

Terraform expressions can be inserted into strings using `${}`.

Example:

```hcl
name = "lab3-${each.key}-nic"
```

During the `web` iteration:

```text
each.key = web
```

Terraform produces:

```text
lab3-web-nic
```

The same block therefore generates:

```text
lab3-web-nic
lab3-app-nic
lab3-db-nic
```

Mental shortcut used during this lab:

```text
${}  → insert an expression into a string

[]   → select an item/key from a collection

()   → call a function or group an expression
```

---

# 6. Resource Instance Lookup

Because the subnet resource uses `for_each`, Terraform creates individually addressable instances.

```text
azurerm_subnet.subnets["web"]

azurerm_subnet.subnets["app"]

azurerm_subnet.subnets["db"]
```

This becomes extremely useful when connecting resources together.

For example:

```hcl
subnet_id = azurerm_subnet.subnets[each.key].id
```

During the `app` iteration, Terraform effectively evaluates:

```hcl
azurerm_subnet.subnets["app"].id
```

This allows resources using the same map keys to automatically connect to each other.

---

# 7. Data-Driven NIC Creation

The same subnet map was reused to create the NIC layer.

```hcl
resource "azurerm_network_interface" "nics" {
  for_each = var.subnets

  name                = "lab3-${each.key}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnets[each.key].id
    private_ip_address_allocation = "Dynamic"
  }
}
```

This creates:

```text
web → web-subnet → web-nic

app → app-subnet → app-nic

db  → db-subnet  → db-nic
```

The important concept is that the same map key ties related resources together.

---

# 8. Data-Driven VM Creation

The same pattern was then extended to Linux VMs.

```hcl
resource "azurerm_linux_virtual_machine" "vms" {
  for_each = var.subnets

  name                = "lab3-${each.key}-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = "Standard_B1s"
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.nics[each.key].id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("/home/syed/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
```

The same keys now connect the entire architecture:

```text
"web"
  │
  ├── web-subnet
  │
  ├── web-nic
  │
  └── web-vm


"app"
  │
  ├── app-subnet
  │
  ├── app-nic
  │
  └── app-vm


"db"
  │
  ├── db-subnet
  │
  ├── db-nic
  │
  └── db-vm
```

This was the main Terraform programming lesson from Lab 3.

---

# 9. Terraform `file()` Function

The VM configuration also introduced a Terraform function:

```hcl
file("/home/syed/.ssh/id_rsa.pub")
```

`file()` reads the contents of a file and returns them to Terraform.

```text
SSH public key file
       │
       ▼
     file()
       │
       ▼
Public key contents
       │
       ▼
Azure VM configuration
```

The local SSH-key approach was acceptable for this learning lab.

Future labs will move toward more professional Azure VM access patterns instead of treating a developer's personal local SSH key as the standard production design.

---

# 10. Azure Blob Remote State

Terraform state was moved away from the local workstation and stored in Azure Blob Storage.

Example backend structure:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "<resource-group-name>"
    storage_account_name = "<storage-account-name>"
    container_name       = "lab3"
    key                  = "lab3/terraform.tfstate"
  }
}
```

Architecture:

```text
Developer / Terraform
          │
          ▼
Azure Storage Account
          │
          ▼
Container: lab3
          │
          ▼
lab3/terraform.tfstate
```

Remote state is an important foundation for later CI/CD workflows because Terraform execution will not depend on a state file stored only on one engineer's laptop.

---

# Backend Bootstrap

The backend infrastructure must exist before Terraform can use it as a backend.

For this lab, the backend storage account and container were bootstrapped separately using Azure CLI.

Example pattern:

```bash
az storage account create \
  --name <storage-account-name> \
  --resource-group <resource-group-name> \
  --location westus \
  --sku Standard_LRS
```

Then the state container was created:

```bash
az storage container create \
  --name lab3 \
  --account-name <storage-account-name> \
  --auth-mode login
```

After configuring `backend.tf`, Terraform was reinitialized:

```bash
terraform init -reconfigure
```

---

# Troubleshooting

Troubleshooting was intentionally documented because understanding failures is part of learning Terraform.

## Issue 1 — Backend Did Not Exist

Terraform initialization initially failed because the backend configuration referenced an Azure Storage Account that had not yet been created.

### Lesson

Terraform cannot initialize a remote backend against infrastructure that does not exist.

The backend must first be bootstrapped separately.

---

## Issue 2 — Invalid Azure Storage Resource Name

Terraform later returned an error similar to:

```text
400 The specified resource name contains invalid characters.
InvalidResourceName
```

The issue involved Azure Storage naming requirements.

Azure Storage resource names such as storage account and blob container names have stricter naming rules than many general Azure resources.

The configuration was corrected to use valid lowercase names.

After correcting the backend values:

```bash
terraform init -reconfigure
```

completed successfully.

### Lesson

Cloud provider naming restrictions matter even when the Terraform syntax itself is valid.

---

# Terraform Validation Workflow

Throughout the lab, changes were checked incrementally.

```bash
terraform fmt
```

Formats Terraform configuration.

```bash
terraform validate
```

Checks whether the Terraform configuration is syntactically and internally valid.

```bash
terraform plan
```

Shows the infrastructure changes Terraform intends to make.

An important validation point occurred after implementing the subnet loop.

Terraform reported:

```text
Plan: 4 to add, 0 to change, 0 to destroy.
```

Those four resources represented:

```text
1 VNet
+
3 dynamically generated subnets
=
4 resources
```

This confirmed that one subnet resource block using `for_each` successfully expanded into three independent Azure resources.

---

# Important Terraform Resource Addresses

The lab demonstrated how `for_each` changes resource addressing.

Instead of one subnet address:

```text
azurerm_subnet.subnets
```

Terraform tracks individual instances:

```text
azurerm_subnet.subnets["web"]
azurerm_subnet.subnets["app"]
azurerm_subnet.subnets["db"]
```

Likewise, the NICs can be addressed as:

```text
azurerm_network_interface.nics["web"]
azurerm_network_interface.nics["app"]
azurerm_network_interface.nics["db"]
```

And VMs:

```text
azurerm_linux_virtual_machine.vms["web"]
azurerm_linux_virtual_machine.vms["app"]
azurerm_linux_virtual_machine.vms["db"]
```

This becomes important later for:

- state management
- imports
- troubleshooting
- targeted inspection
- modules
- refactoring infrastructure

---

# Repository Structure

```text
.
├── .gitignore
├── .terraform.lock.hcl
├── backend.tf
├── main.tf
├── outputs.tf
├── providers.tf
├── variables.tf
├── versions.tf
└── README.md
```

`terraform.tfvars` is intentionally excluded from Git by `.gitignore`.

---

# Git Safety

Terraform-generated state and local working files should not be committed.

Example `.gitignore` entries:

```gitignore
.terraform/

*.tfstate
*.tfstate.*

*.tfplan
tfplan

crash.log
crash.*.log

*.tfvars
*.tfvars.json

override.tf
override.tf.json
*_override.tf
*_override.tf.json

.DS_Store
.vscode/
.idea/
```

The Terraform provider lock file:

```text
.terraform.lock.hcl
```

is committed so provider dependency selections remain reproducible.

---

# Lab 3 CI/CD Limitation

The original goal was to introduce:

```text
Feature Branch
      │
      ▼
Pull Request
      │
      ▼
GitHub Actions CI
      │
      ▼
Terraform Plan
      │
      │ OIDC
      ▼
Microsoft Entra ID
      │
      ▼
Azure
```

and:

```text
Merge → main
      │
      ▼
GitHub Actions CD
      │
      ▼
Terraform Apply
```

However, the temporary Azure sandbox account did not provide permission to create/manage the required Microsoft Entra application/service principal and federated identity configuration.

Rather than replacing OIDC with an intentionally weaker long-lived credential solely to complete the demonstration, CI/CD was deferred to the next lab in an Azure environment where the complete identity architecture can be implemented.

This limitation itself provided an important cloud engineering lesson:

> Infrastructure automation is constrained not only by Terraform code, but also by identity, RBAC, tenant permissions, and organizational security boundaries.

---

# Lab 4 Direction

Lab 4 will build on Lab 3 rather than starting over.

Concepts that will be reused include:

```text
variables
terraform.tfvars
map(object)
map keys
objects
for_each
each.key
each.value
string interpolation
resource references
remote state
```

A new Terraform programmability concept will then be introduced on top of those foundations.

Lab 4 is also intended to introduce the professional CI/CD workflow:

```text
Developer
    │
    ▼
Feature Branch
    │
    ▼
Pull Request
    │
    ▼
GitHub Actions CI
    │
    ├── terraform fmt
    ├── terraform validate
    ├── security/static checks
    └── terraform plan
             │
             ▼
       Azure via OIDC

PR Review
    │
    ▼
Merge → main
    │
    ▼
GitHub Actions CD
    │
    ▼
terraform apply
    │
    ▼
Azure
```

The goal is to use **OIDC/workload identity federation rather than storing a long-lived Azure client secret in GitHub**.

VM access will also move away from treating a developer's personal local SSH key or password-based login as the standard infrastructure design.

---

# Terraform Learning Progression

This repository is part of a larger Terraform learning series.

## Labs 3–8 — Terraform Engineering Foundations

Each lab will:

1. Reuse concepts learned in previous labs.
2. Introduce a new Terraform language/programming concept.
3. Apply the concepts to real Azure infrastructure.
4. Increase automation and engineering quality.
5. Gradually introduce reusable modules and professional CI/CD patterns.

The goal is cumulative learning rather than learning a Terraform feature once and forgetting it.

Concepts will progressively include areas such as:

```text
Variables
Collections
map(object)
for_each
count
Conditionals
Locals
Functions
Dynamic blocks
Data sources
Modules
Outputs
Remote state
Environment patterns
Git workflows
CI/CD
OIDC
Security validation
```

## Labs 9–20 — Advanced Azure Infrastructure

Starting with Lab 9, the focus shifts from isolated Terraform concepts to larger infrastructure projects.

The expectation will be to combine the concepts learned in Labs 3–8 when building more advanced Azure architectures.

```text
Terraform Language
       +
Reusable Modules
       +
Azure Networking
       +
Identity
       +
Security
       +
Remote State
       +
CI/CD
       +
OIDC
       ↓
Real Infrastructure Projects
```

The long-term objective is not simply knowing Terraform syntax.

The objective is being able to **design, automate, validate, troubleshoot, and safely deploy Azure infrastructure using Terraform as part of a professional engineering workflow.**

---

# Key Takeaway

The biggest lesson from Lab 3 was the transition from:

```text
Write one resource block
for every Azure resource
```

to:

```text
Describe infrastructure as structured data
              │
              ▼
         map(object)
              │
              ▼
           for_each
              │
              ▼
Terraform generates and connects
multiple infrastructure resources
```

The final pattern:

```text
                    var.subnets
                        │
           ┌────────────┼────────────┐
           │            │            │
          web          app           db
           │            │            │
           ▼            ▼            ▼
       web-subnet   app-subnet    db-subnet
           │            │            │
           ▼            ▼            ▼
        web-nic      app-nic       db-nic
           │            │            │
           ▼            ▼            ▼
         web-vm       app-vm        db-vm
```

One structured Terraform map drives multiple layers of Azure infrastructure.

That is the foundation this lab was designed to establish.
