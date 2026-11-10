# 7. AWS Amplify Hosting instead of a self-managed CloudFront distribution

Date: 2026-11-10
Status: Accepted (supersedes the CloudFront part of the original site design)

## Context

`CreateDistribution` failed with "Your account must be verified before you can
add new CloudFront resources", and AWS Support declined to lift the restriction
for this account. The site still needs a CDN, HTTPS with an A+ grade, custom
security headers, IPv6 and the apex domain on Route 53.

Options considered:

| Option | Verdict |
|---|---|
| S3 static website endpoint | HTTP only on a custom domain: no TLS, no headers |
| Cloudflare in front of S3 | Moves DNS out of Route 53 and needs a public bucket |
| API Gateway + Lambda serving files | Cold starts on every page, more code to own |
| Lightsail + nginx | Single instance, no CDN, ~$5/month, patching |
| **Amplify Hosting** | CloudFront runs in Amplify's account, so the restriction does not apply |

Verified on 2026-11-10 with a throwaway app before committing: deployment from a
zip, custom headers, apex + www on our own ACM certificate, TLS 1.3/1.2 only.

## Decision

- Amplify app without a Git connection; CI uploads the build as
  `s3://…/releases/site.zip` and calls `StartDeployment` with that S3 URL.
- The bucket is versioned and keeps at least the 5 most recent releases, so
  `rollback.yml` redeploys any of them without rebuilding.
- Our own ACM certificate (`certificate_settings { type = "CUSTOM" }`):
  Amplify's managed certificate includes a wildcard, which the CAA record forbids.
  CAA now also lists `amazontrust.com`, which Amplify checks for explicitly.
- Security headers move from a CloudFront response headers policy to
  `custom-headers.yml`; `www` → apex and the 404 page become Amplify rewrite rules.
- `/live/*` is reverse-proxied by Amplify to `live/` in the bucket, so the
  monitoring JSON stays same-origin and the CSP keeps `connect-src 'self'`.
  `live/*` is public-read by bucket policy; `releases/` is readable only by the
  Amplify service principal from this account.
- Route 53 records stay in Terraform (`allow_overwrite`) and add AAAA, which
  Amplify does not create.

## Consequences

- Lost: CloudFront Functions, removal of the `Server` header, and our own
  choice of price class and TLS policy (Amplify's defaults reject TLS 1.1).
- Amplify's bucket policy check rejects `aws:SourceArn` conditions, so read
  access to releases is scoped by account and prefix, not by app.
- If the CloudFront restriction is lifted, the previous design is in git
  history and the release bucket can become its origin again.
