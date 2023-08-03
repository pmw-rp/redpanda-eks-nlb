#########################################################
### Data Section to find the required VPC and Subnets ###
#########################################################

# Find a pre-existing EKS cluster by name
data "aws_eks_cluster" "default" {
  name = var.cluster_name
}

# Find a pre-existing VPC using the EKS cluster
data "aws_vpc" "default" {
  id = data.aws_eks_cluster.default.vpc_config[0].vpc_id
}

# Find pre-existing subnets using the VPC of the EKS cluster
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# Find the public subnets by filtering for "public IP on launch == true"
locals {
  public_subnets = toset([for subnet in data.aws_subnet.default: subnet.id if subnet.map_public_ip_on_launch == true])
}

################################################
### Install the AWS Load Balancer Controller ###
################################################

locals {
  sa_namespace = "kube-system"
  sa_name      = "aws-load-balancer-controller"
}

# TLS certificate of the OpenID provider - the ARN is required by the IAM policy
data "tls_certificate" "eks" {
  url = data.aws_eks_cluster.default.identity[0].oidc[0].issuer
}

# OpenID provider - the ARN is required by the IAM policy
data "aws_iam_openid_connect_provider" "k8s-iam-connector" {
  url = data.aws_eks_cluster.default.identity[0].oidc[0].issuer
}

# Define the policy needed by the AWS Load Balancer Controller
resource "aws_iam_policy" "k8s-lb-controller-policy" {
  name        = local.sa_name
  path        = "/k8s/"
  description = "AWS Ingress Controller policy"
  policy      = file("aws-ingress-controller.json")
}

# Create the IAM role that will be assumed by the service account in K8s
resource "aws_iam_role" "k8s-lb-controller-role" {
  name                  = "aws-load-balancer-controller"
  path                  = "/k8s/"
  force_detach_policies = true
  managed_policy_arns   = [aws_iam_policy.k8s-lb-controller-policy.arn]
  assume_role_policy = templatefile("aws-ingress-controller-assume.json", {
    OIDC_ARN  = data.aws_iam_openid_connect_provider.k8s-iam-connector.arn,
    OIDC_URL  = data.aws_iam_openid_connect_provider.k8s-iam-connector.url,
    NAMESPACE = local.sa_namespace,
  SA_NAME = local.sa_name })
}

# Create a service account in Kubernetes, connected to the IAM role, that will be used by the controller
# to create the target group bindings needed.
resource "kubernetes_service_account" "k8s-lb-controller-sa" {
  metadata {
    name      = local.sa_name
    namespace = local.sa_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.k8s-lb-controller-role.arn
    }
  }
}

# Install the Load Balancer Controller using Helm
resource "helm_release" "aws-load-balancer-controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = local.sa_namespace
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  depends_on = [kubernetes_service_account.k8s-lb-controller-sa, aws_iam_role.k8s-lb-controller-role]
}

######################
### Create the NLB ###
######################

# Import our NLB cert into AWS Cert Manager
resource "aws_acm_certificate" "default" {
  private_key = file("cert/privkey.pem")
  certificate_body = file("cert/cert.pem")
  certificate_chain = file("cert/chain.pem")
}

locals {
  ports = [for i in range(var.brokers) : (local.base + i)]
  rules = {for pair in setproduct(local.ports, var.cidrs_allowed) : pair[0] => pair[1]...}
}

resource "aws_security_group_rule" "example" {
  for_each = local.rules
  type              = "ingress"
  from_port         = each.key
  to_port           = each.key
  protocol          = "tcp"
  cidr_blocks       = each.value
  security_group_id = data.aws_eks_cluster.default.vpc_config[0].cluster_security_group_id
}


# Create the NLB
resource "aws_lb" "nlb" {
  name = "my-nlb"
  internal = false
  load_balancer_type = "network"
  security_groups = []
  subnets = local.public_subnets
}

# Used to lookup the IP addresses of the NLB
data "dns_a_record_set" "foo" {
  host = aws_lb.nlb.dns_name
}

# Outputs the IP addresses of the NLB for the user to ensure are created externally
output "load_balancer_ip_addresses" {
  value = data.dns_a_record_set.foo
}

# Create the Target Groups (One per broker)
resource "aws_lb_target_group" "target-groups" {
  count = var.brokers
  name = "tf-lb-tg-kafka-${count.index}"
  port = 9094
  protocol = "TCP"
  vpc_id = data.aws_vpc.default.id
}

## Create the NLB listeners, on incrementing ports, that map to the target groups
resource "aws_lb_listener" "listener" {
  count = var.brokers
  load_balancer_arn = aws_lb.nlb.arn
  port = 9094 + count.index
  protocol = "TLS"
  certificate_arn = aws_acm_certificate.default.arn
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.target-groups[count.index].arn
  }
}

#######################################################
### Integrate the NLB into the Redpanda K8s cluster ###
#######################################################

locals {
  base = 30000
}

# Service (One per Broker)
# Built using a raw manifest since the official resource doesn't support external traffic policy.
resource "kubernetes_manifest" "service" {
  count = var.brokers
  manifest = {
    "apiVersion" = "v1"
    "kind" = "Service"
    "metadata" = {
      "annotations" = {
        "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port" = tostring(local.base + count.index * 10)
      }
      "name" = "redpanda-${count.index}"
      "namespace" = "redpanda"
    }
    "spec" = {
      "externalTrafficPolicy" = "Local"
      "ports" = [
        {
          "name" = "kafka"
          "port" = 9094
          "protocol" = "TCP"
          "targetPort" = 9094
          "nodePort" = local.base + count.index * 10
        },
        {
          "name" = "registry"
          "port" = 8084
          "protocol" = "TCP"
          "targetPort" = 8084
          "nodePort" = local.base + 1 + count.index * 10
        },
        {
          "name" = "proxy"
          "port" = 8083
          "protocol" = "TCP"
          "targetPort" = 8083
          "nodePort" = local.base + 2 + count.index * 10
        },
      ]
      "selector" = {
        "statefulset.kubernetes.io/pod-name" = "redpanda-${count.index}"
      }
      "type" = "NodePort"
    }
  }
  depends_on = [aws_lb.nlb]
}

# An AWS Load Balancer Controller Target Group Binding, that connects binds the NodePort Service
# to the Target Group for use by the NLB.
resource "kubernetes_manifest" "binding" {
  count = var.brokers
  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata   = {
      name      = "kafka-${count.index}-binding"
      namespace = "redpanda"
    }
    spec = {
      serviceRef = {
        name = "redpanda-${count.index}"
        port = 9094
      }
      targetGroupARN = aws_lb_target_group.target-groups[count.index].arn
    }
  }
  depends_on = [kubernetes_manifest.service]
}