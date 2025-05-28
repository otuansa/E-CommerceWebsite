provider "aws" {
    region = var.region
}

provider "kubernetes" {
    host                   = aws_eks_cluster.eks_cluster.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
    exec {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "aws"
        args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.name, "--region", var.region]
    }
}

# VPC Resources
resource "aws_vpc" "eks_vpc" {
    cidr_block           = var.vpc_cidr
    enable_dns_hostnames = true
    enable_dns_support   = true

    tags = {
        Name = "${var.cluster_name}-vpc"
    }
}

# Create 2 public and 2 private subnets across different AZs
resource "aws_subnet" "public" {
    count                   = 2
    vpc_id                  = aws_vpc.eks_vpc.id
    cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
    availability_zone       = data.aws_availability_zones.available.names[count.index]
    map_public_ip_on_launch = true

    tags = {
        Name                                        = "${var.cluster_name}-public-subnet-${count.index}"
        "kubernetes.io/cluster/${var.cluster_name}" = "shared"
        "kubernetes.io/role/elb"                    = "1"
    }
}

resource "aws_subnet" "private" {
    count             = 2
    vpc_id            = aws_vpc.eks_vpc.id
    cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
    availability_zone = data.aws_availability_zones.available.names[count.index]

    tags = {
        Name                                        = "${var.cluster_name}-private-subnet-${count.index}"
        "kubernetes.io/cluster/${var.cluster_name}" = "shared"
        "kubernetes.io/role/internal-elb"           = "1"
    }
}

# Get available AZs
data "aws_availability_zones" "available" {}

# Internet Gateway for public subnets
resource "aws_internet_gateway" "igw" {
    vpc_id = aws_vpc.eks_vpc.id

    tags = {
        Name = "${var.cluster_name}-igw"
    }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
    domain = "vpc"

    tags = {
        Name = "${var.cluster_name}-nat-eip"
    }
}

# NAT Gateway for private subnets
resource "aws_nat_gateway" "nat" {
    allocation_id = aws_eip.nat.id
    subnet_id     = aws_subnet.public[0].id

    tags = {
        Name = "${var.cluster_name}-nat"
    }

    depends_on = [aws_internet_gateway.igw]
}

# Route table for public subnets
resource "aws_route_table" "public" {
    vpc_id = aws_vpc.eks_vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
    }

    tags = {
        Name = "${var.cluster_name}-public-rt"
    }
}

# Route table associations for public subnets
resource "aws_route_table_association" "public" {
    count          = 2
    subnet_id      = aws_subnet.public[count.index].id
    route_table_id = aws_route_table.public.id
}

# Route table for private subnets
resource "aws_route_table" "private" {
    vpc_id = aws_vpc.eks_vpc.id

    route {
        cidr_block     = "0.0.0.0/0"
        nat_gateway_id = aws_nat_gateway.nat.id
    }

    tags = {
        Name = "${var.cluster_name}-private-rt"
    }
}

# Route table associations for private subnets
resource "aws_route_table_association" "private" {
    count          = 2
    subnet_id      = aws_subnet.private[count.index].id
    route_table_id = aws_route_table.private.id
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
    name = "${var.cluster_name}-cluster-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "eks.amazonaws.com"
                }
            }
        ]
    })
}

# Attach the required policies for EKS
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    role       = aws_iam_role.eks_cluster_role.name
}

# IAM Role for Worker Nodes
resource "aws_iam_role" "eks_node_role" {
    name = "${var.cluster_name}-node-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "ec2.amazonaws.com"
                }
            }
        ]
    })
}

# Attach required policies for EKS worker nodes
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_read_only" {
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    role       = aws_iam_role.eks_node_role.name
}

# Security Group for EKS Cluster
resource "aws_security_group" "eks_cluster_sg" {
    name        = "${var.cluster_name}-cluster-sg"
    description = "Security group for EKS cluster control plane"
    vpc_id      = aws_vpc.eks_vpc.id

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "${var.cluster_name}-cluster-sg"
    }
}

# Security Group for Worker Nodes
resource "aws_security_group" "eks_nodes_sg" {
    name        = "${var.cluster_name}-nodes-sg"
    description = "Security group for EKS worker nodes"
    vpc_id      = aws_vpc.eks_vpc.id

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "${var.cluster_name}-nodes-sg"
    }
}

# Restrict traffic between control plane and worker nodes
resource "aws_security_group_rule" "cluster_to_nodes" {
    description              = "Allow cluster to communicate with worker nodes"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    security_group_id        = aws_security_group.eks_nodes_sg.id
    source_security_group_id = aws_security_group.eks_cluster_sg.id
    type                     = "ingress"
}

resource "aws_security_group_rule" "nodes_to_cluster" {
    description              = "Allow worker nodes to communicate with the cluster"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    security_group_id        = aws_security_group.eks_cluster_sg.id
    source_security_group_id = aws_security_group.eks_nodes_sg.id
    type                     = "ingress"
}

# Allow worker nodes to communicate with each other
resource "aws_security_group_rule" "nodes_self" {
    description       = "Allow worker nodes to communicate with each other"
    from_port         = 0
    to_port           = 65535
    protocol          = "tcp"
    security_group_id = aws_security_group.eks_nodes_sg.id
    self              = true
    type              = "ingress"
}

# EKS Cluster
resource "aws_eks_cluster" "eks_cluster" {
    name     = var.cluster_name
    role_arn = aws_iam_role.eks_cluster_role.arn
    version  = var.kubernetes_version

    vpc_config {
        subnet_ids             = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
        security_group_ids     = [aws_security_group.eks_cluster_sg.id]
        endpoint_private_access = true
        endpoint_public_access  = true
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_cluster_policy
    ]
}

# EKS Node Group
resource "aws_eks_node_group" "eks_node_group" {
    cluster_name    = aws_eks_cluster.eks_cluster.name
    node_group_name = "${var.cluster_name}-node-group"
    node_role_arn   = aws_iam_role.eks_node_role.arn
    subnet_ids      = aws_subnet.private[*].id

    scaling_config {
        desired_size = var.node_group_desired_size
        max_size     = var.node_group_desired_size + 2
        min_size     = 1
    }

    instance_types = ["t3.medium"]
    ami_type       = "AL2_x86_64"

    tags = {
        Name = "${var.cluster_name}-node-group"
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_worker_node_policy,
        aws_iam_role_policy_attachment.eks_cni_policy,
        aws_iam_role_policy_attachment.eks_container_registry_read_only
    ]
}

# Output to get the kubeconfig command
output "kubeconfig_command" {
    value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.eks_cluster.name}"
}

# Output the ECR image URI used
output "ecr_image_uri" {
    value = var.ecr_image_uri
}

# Kubernetes Deployment
resource "kubernetes_deployment" "app" {
    metadata {
        name = "eks-app-deployment"
        labels = {
            app = "eks-app"
        }
    }

    spec {
        replicas = 2

        selector {
            match_labels = {
                app = "eks-app"
            }
        }

        template {
            metadata {
                labels = {
                    app = "eks-app"
                }
            }

            spec {
                container {
                    image = var.ecr_image_uri
                    name  = "app-container"

                    port {
                        container_port = 80
                    }

                    resources {
                        limits = {
                            cpu    = "0.5"
                            memory = "512Mi"
                        }
                        requests = {
                            cpu    = "0.25"
                            memory = "256Mi"
                        }
                    }
                }
            }
        }
    }

    depends_on = [
        aws_eks_node_group.eks_node_group
    ]
}

# Kubernetes Service
resource "kubernetes_service" "app_service" {
    metadata {
        name = "eks-app-service"
    }

    spec {
        selector = {
            app = "eks-app"
        }

        port {
            port        = 80
            target_port = 80
        }

        type = var.service_type
    }

    depends_on = [
        kubernetes_deployment.app
    ]
}