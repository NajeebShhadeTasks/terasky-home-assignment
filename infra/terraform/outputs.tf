output "region" {
  description = "AWS region of the demo environment"
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS Kubernetes version"
  value       = module.eks.cluster_version
}

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL for the backend image"
  value       = aws_ecr_repository.backend.repository_url
}

output "gha_ecr_role_arn" {
  description = "IAM role assumed by GitHub Actions to push images"
  value       = aws_iam_role.gha_ecr.arn
}

output "gha_terraform_role_arn" {
  description = "IAM role assumed by GitHub Actions for terraform plan/apply"
  value       = aws_iam_role.gha_terraform.arn
}

output "eso_role_arns" {
  description = "Per-environment IRSA roles used by External Secrets Operator"
  value       = { for env, role in aws_iam_role.eso : env => role.arn }
}

output "secretsmanager_secret_names" {
  description = "Secrets Manager secret containers (values are set out-of-band)"
  value       = { for env, s in aws_secretsmanager_secret.backend : env => s.name }
}

output "vpc_id" {
  description = "Demo VPC id"
  value       = module.vpc.vpc_id
}
