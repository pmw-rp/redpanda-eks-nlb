variable "region" {
  type        = string
  description = "AWS Region; used for locating infra"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name; used for resource tags"
}

variable "brokers" {
  type        = number
  description = "Number of brokers in the cluster; used to determine how many target groups, listeners, services and target group bindings to create"
}

variable "cidrs_allowed" {
  type = list(string)
  description = "CIDRs that allowed to access the cluster via the NLB; used in security group rules"
}