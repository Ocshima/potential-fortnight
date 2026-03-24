# ============================================================
# Makefile — Secure Static Website
# Convenience wrappers around AWS CLI commands.
# Requires: aws-cli v2, cfn-lint (pip install cfn-lint)
# ============================================================

STACK_NAME   ?= secure-static-site
REGION       ?= us-east-1
DOMAIN       ?= $(shell aws cloudformation describe-stacks \
                  --stack-name $(STACK_NAME) --region $(REGION) \
                  --query "Stacks[0].Outputs[?OutputKey=='WebsiteURL'].OutputValue" \
                  --output text 2>/dev/null)
BUCKET       ?= $(shell aws cloudformation describe-stacks \
                  --stack-name $(STACK_NAME) --region $(REGION) \
                  --query "Stacks[0].Outputs[?OutputKey=='ContentBucketName'].OutputValue" \
                  --output text 2>/dev/null)
DIST_ID      ?= $(shell aws cloudformation describe-stacks \
                  --stack-name $(STACK_NAME) --region $(REGION) \
                  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
                  --output text 2>/dev/null)
ATHENA_BUCKET ?= $(shell aws cloudformation describe-stacks \
                  --stack-name $(STACK_NAME) --region $(REGION) \
                  --query "Stacks[0].Outputs[?OutputKey=='AthenaResultsBucketName'].OutputValue" \
                  --output text 2>/dev/null)

.PHONY: help lint validate deploy-bootstrap deploy-infra deploy-website \
        invalidate outputs destroy empty-bucket empty-athena-results clean-athena

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Linting ──────────────────────────────────────────────────
lint: ## Lint CloudFormation templates with cfn-lint
	-cfn-lint infrastructure/template.yaml --include-checks W
	-cfn-lint infrastructure/oidc-bootstrap.yaml --include-checks W
	@echo "✅ Lint passed (ignored warnings)"

validate: ## Validate templates against the CloudFormation API
	aws cloudformation validate-template \
	  --template-body file://infrastructure/template.yaml \
	  --region $(REGION)
	@echo "✅ Template valid"

# ── Bootstrap (run once) ─────────────────────────────────────
deploy-bootstrap: ## Deploy the OIDC bootstrap stack
	@[ -n "$(GITHUB_ORG)" ]  || (echo "❌ Set GITHUB_ORG=your-username" && exit 1)
	@[ -n "$(GITHUB_REPO)" ] || (echo "❌ Set GITHUB_REPO=your-repo"    && exit 1)
	aws cloudformation deploy \
	  --template-file infrastructure/oidc-bootstrap.yaml \
	  --stack-name github-oidc-bootstrap \
	  --parameter-overrides \
	      GitHubOrg=$(GITHUB_ORG) \
	      GitHubRepo=$(GITHUB_REPO) \
	      MainStackName=$(STACK_NAME) \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --region $(REGION)
	@echo "✅ Bootstrap deployed. Copy the RoleArn output into GitHub secrets"

# ── Main Stack ───────────────────────────────────────────────
deploy-infra: lint validate ## Deploy / update the main infrastructure stack
	aws cloudformation deploy \
	  --template-file infrastructure/template.yaml \
	  --stack-name $(STACK_NAME) \
	  --parameter-overrides \
	      DomainName=$(DOMAIN_NAME) \
	      HostedZoneId=$(HOSTED_ZONE_ID) \
	      SubDomain=www \
	      Environment=prod \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --no-fail-on-empty-changeset \
	  --region $(REGION)
	@echo "✅ Infrastructure deployed"
	@$(MAKE) outputs

deploy-website: ## Sync website files to S3 and invalidate CloudFront
	@[ -n "$(BUCKET)" ]  || (echo "❌ Could not resolve bucket" && exit 1)
	@[ -n "$(DIST_ID)" ] || (echo "❌ Could not resolve distribution ID" && exit 1)
	@echo "📦 Syncing HTML files..."
	aws s3 sync website/ s3://$(BUCKET)/ \
	  --exclude "*" --include "*.html" \
	  --cache-control "public, max-age=300, must-revalidate" \
	  --delete --region $(REGION)
	@echo "📦 Syncing static assets..."
	aws s3 sync website/ s3://$(BUCKET)/ \
	  --exclude "*.html" \
	  --cache-control "public, max-age=31536000, immutable" \
	  --delete --region $(REGION)
	@$(MAKE) invalidate

invalidate: ## Create a CloudFront cache invalidation
	@[ -n "$(DIST_ID)" ] || (echo "❌ Could not resolve distribution ID" && exit 1)
	aws cloudfront create-invalidation \
	  --distribution-id $(DIST_ID) \
	  --paths "/*"
	@echo "✅ Invalidation submitted"

outputs: ## Print CloudFormation stack outputs
	aws cloudformation describe-stacks \
	  --stack-name $(STACK_NAME) \
	  --region $(REGION) \
	  --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
	  --output table

# ── Teardown ─────────────────────────────────────────────────
empty-bucket: ## Empty the versioned content bucket (versions + delete markers)
	@echo "🗑️  Emptying versioned content bucket: $(BUCKET)"
	@if [ -n "$(BUCKET)" ]; then \
		VERSIONS=$$(aws s3api list-object-versions --bucket $(BUCKET) --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json); \
		if [ "$$VERSIONS" != "null" ] && [ "$$VERSIONS" != "[]" ]; then \
			aws s3api delete-objects --bucket $(BUCKET) --delete "{\"Objects\":$$VERSIONS}"; \
		fi; \
		MARKERS=$$(aws s3api list-object-versions --bucket $(BUCKET) --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json); \
		if [ "$$MARKERS" != "null" ] && [ "$$MARKERS" != "[]" ]; then \
			aws s3api delete-objects --bucket $(BUCKET) --delete "{\"Objects\":$$MARKERS}"; \
		fi; \
	fi
	@echo "✅ Content bucket emptied."

empty-athena-results: ## Empty the Athena query results bucket (no versioning)
	@echo "🗑️  Emptying Athena results bucket: $(ATHENA_BUCKET)"
	@if [ -n "$(ATHENA_BUCKET)" ]; then \
		aws s3 rm s3://$(ATHENA_BUCKET) --recursive --region $(REGION) 2>/dev/null || true; \
	fi
	@echo "✅ Athena results bucket emptied." 

clean-athena: ## Force-delete the Athena WorkGroup and all its contents
	@echo "🧹 Force-deleting Athena WorkGroup: $(STACK_NAME)-logs"
	@# --recursive-delete-option removes the workgroup AND all query history in one call.
	@# batch-delete-query-execution does NOT clear history, so CloudFormation would still
	@# see a non-empty workgroup and fail. The workgroup has DeletionPolicy: Retain in the
	@# template so CloudFormation skips it cleanly after this pre-delete step.
	@aws athena delete-work-group \
		--work-group $(STACK_NAME)-logs \
		--recursive-delete-option \
		--region $(REGION) 2>/dev/null \
	  && echo "✅ Athena WorkGroup deleted." \
	  || echo "ℹ️  WorkGroup not found or already deleted — continuing."

destroy: ## ⚠️ Delete stack and all resources 
	@echo "⚠️  Deleting stack: $(STACK_NAME)"
	@read -p "   Type the stack name to confirm: " confirm; \
	  [ "$$confirm" = "$(STACK_NAME)" ] || (echo "Aborted." && exit 1) 
	@$(MAKE) empty-bucket
	@$(MAKE) empty-athena-results
	@$(MAKE) clean-athena
	aws cloudformation delete-stack --stack-name $(STACK_NAME) --region $(REGION)
	aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME) --region $(REGION)
	@echo "✅ Stack deleted."