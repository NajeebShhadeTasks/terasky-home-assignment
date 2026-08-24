# Secrets Manager secret CONTAINERS only. Secret VALUES are never written by
# Terraform (they would end up in plan output and state). Values are set
# out-of-band with a secure CLI call, e.g.:
#
#   aws secretsmanager put-secret-value \
#     --secret-id terasky/dev/backend \
#     --secret-string '{"apiKey":"<value>"}'
#
resource "aws_secretsmanager_secret" "backend" {
  for_each = toset(var.environments)

  name        = "terasky/${each.key}/backend"
  description = "Backend application secret material for the ${each.key} environment"

  # Demo convenience: allow immediate deletion on cleanup. Production would use
  # the default 30-day recovery window.
  recovery_window_in_days = 0

  tags = {
    Environment = each.key
  }
}
