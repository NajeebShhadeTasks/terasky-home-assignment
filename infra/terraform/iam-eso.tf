# Per-environment IRSA roles for External Secrets Operator.
#
# Least privilege + environment separation: the SecretStore in namespace X
# authenticates with the `eso-backend` ServiceAccount of namespace X, which can
# assume ONLY the role for X, which can read ONLY terasky/X/backend.
data "aws_iam_policy_document" "eso_trust" {
  for_each = toset(var.environments)

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${each.key}:eso-backend"]
    }
  }
}

data "aws_iam_policy_document" "eso_permissions" {
  for_each = toset(var.environments)

  statement {
    sid    = "ReadOwnEnvironmentSecretOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.backend[each.key].arn]
  }
}

resource "aws_iam_role" "eso" {
  for_each = toset(var.environments)

  name               = "${var.project_name}-eso-${each.key}"
  description        = "External Secrets Operator IRSA role for the ${each.key} namespace"
  assume_role_policy = data.aws_iam_policy_document.eso_trust[each.key].json

  tags = {
    Environment = each.key
  }
}

resource "aws_iam_role_policy" "eso" {
  for_each = toset(var.environments)

  name   = "secretsmanager-read-${each.key}"
  role   = aws_iam_role.eso[each.key].id
  policy = data.aws_iam_policy_document.eso_permissions[each.key].json
}
