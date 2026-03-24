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

.PHONY: help lint validate deploy-bootstrap deploy-infra deploy-website \
        invalidate outputs destroy

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
deploy-bootstrap: ## Deploy the OIDC bootstrap stack (run once per account)
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
	@echo "✅ Bootstrap deployed. Copy the RoleArn output into GitHub secrets as AWS_ROLE_ARN"
	aws cloudformation describe-stacks \
	  --stack-name github-oidc-bootstrap \
	  --region $(REGION) \
	  --query "Stacks[0].Outputs"

# ── Main Stack ───────────────────────────────────────────────
deploy-infra: lint validate ## Deploy / update the main infrastructure stack
#	@[ -n "$(DOMAIN_NAME)" ]    || (echo "❌ Set DOMAIN_NAME=yourdomain.com"      && exit 1)
#	@[ -n "$(HOSTED_ZONE_ID)" ] || (echo "❌ Set HOSTED_ZONE_ID=ZXXXXXXXXXXXXX"   && exit 1)
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
	@[ -n "$(BUCKET)" ]  || (echo "❌ Could not resolve bucket — is the stack deployed?" && exit 1)
	@[ -n "$(DIST_ID)" ] || (echo "❌ Could not resolve distribution ID"                 && exit 1)
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

invalidate: ## Create a CloudFront cache invalidation for /*
	@[ -n "$(DIST_ID)" ] || (echo "❌ Could not resolve distribution ID" && exit 1)
	aws cloudfront create-invalidation \
	  --distribution-id $(DIST_ID) \
	  --paths "/*"
	@echo "✅ Invalidation submitted for distribution $(DIST_ID)"

outputs: ## Print CloudFormation stack outputs
	aws cloudformation describe-stacks \
	  --stack-name $(STACK_NAME) \
	  --region $(REGION) \
	  --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
	  --output table

# ── Teardown ─────────────────────────────────────────────────
empty-bucket: ## Use s3api to remove all versions and delete markers (Required for versioned buckets)
	@echo "🗑️  Emptying versioned content bucket: $(BUCKET)"
	@if [ -n "$(BUCKET)" ]; then \
		VERSIONS=$$(aws s3api list-object-versions --bucket $(BUCKET) --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}'); \
		if [ "$$VERSIONS" != '{"Objects": null}' ]; then \
			aws s3api delete-objects --bucket $(BUCKET) --delete "$$VERSIONS"; \
		fi; \
		MARKERS=$$(aws s3api list-object-versions --bucket $(BUCKET) --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}'); \
		if [ "$$MARKERS" != '{"Objects": null}' ]; then \
			aws s3api delete-objects --bucket $(BUCKET) --delete "$$MARKERS"; \
		fi; \
	fi

destroy: ## ⚠️  Delete the main stack and all resources (including versioned S3 content)
	@echo "⚠️  This will delete all resources in stack: $(STACK_NAME)"
	@echo "   The LogsBucket will be RETAINED (DeletionPolicy: Retain)"
	@read -p "   Type the stack name to confirm: " confirm; \
	  [ "$$confirm" = "$(STACK_NAME)" ] || (echo "Aborted." && exit 1)
	@$(MAKE) empty-bucket
	@echo "🗑️  Deleting CloudFormation stack..."
	aws cloudformation delete-stack \
	  --stack-name $(STACK_NAME) \
	  --region $(REGION)
	aws cloudformation wait stack-delete-complete \
	  --stack-name $(STACK_NAME) \
	  --region $(REGION)
	@echo "✅ Stack deleted. LogsBucket is retained — empty and delete it manually if needed."