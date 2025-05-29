variable "region" {
    description = "AWS region to deploy resources"
    type        = string
    default     = "eu-west-2"
}

variable "cluster_name" {
    description = "Name of the EKS cluster"
    type        = string
    default     = "your-eks-cluster-name"
}

variable "vpc_cidr" {
    description = "CIDR block for the VPC"
    type        = string
    default     = "10.0.0.0/16"
}

variable "ecr_image_uri" {
    description = "URI of the image in ECR"
    type        = string
    default     = ""
}

variable "kubernetes_version" {
    description = "Kubernetes version to use for the EKS cluster"
    type        = string
    default     = "1.29"
}

variable "node_group_desired_size" {
    description = "Desired number of nodes in the EKS node group"
    type        = number
    default     = 2
}

variable "service_type" {
    description = "Kubernetes service type"
    type        = string
    default     = "ClusterIP"
}