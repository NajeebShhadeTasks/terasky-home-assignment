# GitHub Actions -> AWS via OIDC. No long-lived AWS keys are stored in GitHub.
#
# The account already has a GitHub OIDC identity provider (used by an unrelated
# project), so it is REUSED via a data source instead of creating a duplicate -
# AWS allows only one provider per URL anyway.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_repo_full = "${var.github_owner}/${var.github_repository}"
}

# ---------------------------------------------------------------------------
# Role 1: CI image publishing. ONLY ECR auth + push/pull on this project's
# repository, trusted ONLY for pushes to main of this exact repository.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gha_ecr_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo_full}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "gha_ecr_permissions" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPullProjectRepoOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.backend.arn]
  }
}

resource "aws_iam_role" "gha_ecr" {
  name                 = "${var.project_name}-gha-ecr"
  description          = "GitHub Actions (${local.github_repo_full}, main branch): push images to the project ECR repository"
  assume_role_policy   = data.aws_iam_policy_document.gha_ecr_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gha_ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.gha_ecr.id
  policy = data.aws_iam_policy_document.gha_ecr_permissions.json
}

# ---------------------------------------------------------------------------
# Role 2: Terraform plan/apply from CI. Necessarily broader, therefore trust
# is restricted to PRs (plan), main (plan) and the protected `production`
# GitHub environment (apply requires human approval there).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gha_terraform_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_repo_full}:pull_request",
        "repo:${local.github_repo_full}:ref:refs/heads/main",
        "repo:${local.github_repo_full}:environment:production",
      ]
    }
  }
}

# PowerUserAccess covers all service operations except IAM management. IAM is
# added back only for resources under this project's prefix, so the role cannot
# touch IAM entities belonging to anything else in the account.
data "aws_iam_policy_document" "gha_terraform_iam_scoped" {
  statement {
    sid    = "ReadOnlyIam"
    effect = "Allow"
    actions = [
      "iam:Get*",
      "iam:List*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageProjectIamOnly"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project_name}-*",
    ]
  }

  statement {
    sid    = "PassProjectRolesOnly"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
    ]
  }

  statement {
    sid    = "ServiceLinkedRoles"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "gha_terraform" {
  name                 = "${var.project_name}-gha-terraform"
  description          = "GitHub Actions (${local.github_repo_full}): terraform plan (PRs) and apply (production environment approval)"
  assume_role_policy   = data.aws_iam_policy_document.gha_terraform_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gha_terraform_poweruser" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "gha_terraform_iam_scoped" {
  name   = "iam-project-scoped"
  role   = aws_iam_role.gha_terraform.id
  policy = data.aws_iam_policy_document.gha_terraform_iam_scoped.json
}
