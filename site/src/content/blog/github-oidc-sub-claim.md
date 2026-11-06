---
title: "Every OIDC login failed, and CloudTrail said why"
description: "GitHub Actions couldn't assume an AWS role because the token's sub claim had a newer format than the trust policy expected. How I found it and why the fix is more secure than the original."
pubDate: 2026-11-06
tags: [aws, github-actions, oidc, iam]
---

This site's CI has no AWS access keys. GitHub Actions gets a signed OIDC token for every
job and trades it with AWS STS for credentials that last one hour. The IAM role's
trust policy decides which workflows are allowed to do that.

Right after the first push, every `terraform plan` job failed on the same step:

```
Run aws-actions/configure-aws-credentials@v4
Error: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

## The trust policy

The plan role trusted any ref in this repository:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:Jesferred/DevOps_AWS:*"]
}
```

That is the format most guides show, and it looked correct.

## What AWS actually received

Rejected `AssumeRoleWithWebIdentity` calls still appear in CloudTrail, and each event
records the `sub` claim from the token:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
```

```
AccessDenied  repo:Jesferred@44315534/DevOps_AWS@1433110978:pull_request
```

GitHub had issued the claim with **immutable numeric IDs** for both the owner and the
repository. `repo:Jesferred/DevOps_AWS:*` never matched it.

## The fix

```hcl
locals {
  repo = "Jesferred@44315534/DevOps_AWS@1433110978"
}
```

This format is also safer. A name-based condition trusts whoever owns that name *now*.
If the repository is renamed or deleted and someone recreates `Jesferred/DevOps_AWS`,
their workflows would get my AWS role. The numeric IDs can't be reused, so that takeover
doesn't work.

## Takeaways

- CloudTrail logs rejected calls as well as successful ones, and for OIDC failures it
  shows the claims AWS was given. Check it before changing the policy by trial and error.
- Pin trust policies to immutable identifiers wherever the identity provider supports them.
- Keep plan and apply in separate roles. Here the apply role trusts only
  `environment:production`, and that environment requires manual approval.
