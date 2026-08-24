#!/usr/bin/env bash
# Local promotion helper - mirrors .github/workflows/promote.yml.
#
#   ./scripts/promote.sh staging sha-a1b2c3d
#   ./scripts/promote.sh production sha-a1b2c3d
#
# Enforces the chain (dev -> staging -> production), updates ONLY Git desired
# state and opens a PR. The same immutable image moves; nothing is rebuilt.
set -euo pipefail

TARGET="${1:?usage: promote.sh <staging|production> <sha-tag>}"
TAG="${2:?usage: promote.sh <staging|production> <sha-tag>}"
IMAGE="647604014014.dkr.ecr.eu-west-1.amazonaws.com/terasky-demo/backend"
REPO_ROOT="$(git rev-parse --show-toplevel)"

case "${TARGET}" in
  staging) SOURCE=dev ;;
  production) SOURCE=staging ;;
  *) echo "target must be staging or production"; exit 1 ;;
esac
case "${TAG}" in
  sha-*) ;;
  *) echo "tag must be an immutable sha-* tag"; exit 1 ;;
esac

CURRENT=$(grep -A1 "name: ${IMAGE}" \
  "${REPO_ROOT}/apps/backend/overlays/${SOURCE}/kustomization.yaml" | grep newTag | awk '{print $2}')
if [ "${CURRENT}" != "${TAG}" ]; then
  echo "REFUSED: ${TARGET} may only receive what ${SOURCE} currently runs (${CURRENT}), got ${TAG}"
  exit 1
fi

TARGET_CURRENT=$(grep -A1 "name: ${IMAGE}" \
  "${REPO_ROOT}/apps/backend/overlays/${TARGET}/kustomization.yaml" | grep newTag | awk '{print $2}')
if [ "${TARGET_CURRENT}" = "${TAG}" ]; then
  echo "${TARGET} already runs ${TAG} - nothing to promote."
  exit 0
fi

# This local helper cannot enforce the GitHub `production` environment
# approval; the canonical production path is the promote.yml workflow.
if [ "${TARGET}" = "production" ] && [ "${PROMOTE_CONFIRM_PRODUCTION:-}" != "yes" ]; then
  echo "REFUSED: production promotions go through the promote.yml workflow"
  echo "(approval-gated). To intentionally bypass from this machine, re-run"
  echo "with PROMOTE_CONFIRM_PRODUCTION=yes."
  exit 1
fi

BRANCH="promote/${TARGET}-${TAG}"
git -C "${REPO_ROOT}" checkout -b "${BRANCH}"
(cd "${REPO_ROOT}/apps/backend/overlays/${TARGET}" && kustomize edit set image "${IMAGE}:${TAG}")
git -C "${REPO_ROOT}" add "apps/backend/overlays/${TARGET}/kustomization.yaml"
git -C "${REPO_ROOT}" commit -m "promote(${TARGET}): ${TAG}"
git -C "${REPO_ROOT}" push origin "${BRANCH}"
gh pr create \
  --title "promote(${TARGET}): ${TAG}" \
  --body "Promotes the SAME immutable image \`${TAG}\` into **${TARGET}** (no rebuild). Rollback = revert this commit." \
  --base main --head "${BRANCH}"
git -C "${REPO_ROOT}" checkout main
