variable "project_name" {
  description = "Prefix for every AWS resource created by this project"
  type        = string
  default     = "terasky-demo"
}

variable "region" {
  description = "AWS region for the demo environment"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC"
  type        = string
  default     = "10.60.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group (modest, general purpose)"
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_group_min_size" {
  description = "Managed node group minimum size"
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Managed node group maximum size"
  type        = number
  default     = 3
}

variable "node_group_desired_size" {
  description = "Managed node group desired size"
  type        = number
  default     = 2
}

variable "github_owner" {
  description = "GitHub repository owner used in OIDC trust conditions"
  type        = string
  default     = "NajeebShhadeTasks"
}

variable "github_repository" {
  description = "GitHub repository name used in OIDC trust conditions"
  type        = string
  default     = "terasky-home-assignment"
}

variable "github_owner_id" {
  description = "Numeric GitHub account id (immutable OIDC subject format)"
  type        = string
  default     = "176375566"
}

variable "github_repository_id" {
  description = "Numeric GitHub repository id (immutable OIDC subject format)"
  type        = string
  default     = "1344950844"
}

variable "environments" {
  description = "Application environments (Kubernetes namespaces + Secrets Manager paths)"
  type        = list(string)
  default     = ["dev", "staging", "production"]
}
