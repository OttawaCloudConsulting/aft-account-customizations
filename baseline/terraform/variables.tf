variable "boundary_policy_name" {
  description = "Name of the default permission boundary policy"
  type        = string
  default     = "Boundary-Default"
}

variable "protected_role_prefix" {
  description = "IAM role prefix protected from creation/modification (e.g., org-*)"
  type        = string
  default     = "org-*"
}

variable "boundary_policy_prefix" {
  description = "Prefix for permission boundary policies (e.g., Boundary-*)"
  type        = string
  default     = "Boundary-*"
}
