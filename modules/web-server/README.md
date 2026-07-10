# Web Server

Secure HTTPS delivery for static content with TLS termination at the edge,
global CDN distribution, and enforced encrypted-only client access.
No servers required — the stack is fully managed and serverless.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed
on the target environment before applying this module.

## Implementations

| Environment | Technology | Doc |
|---|---|---|
| self-managed | Nginx — HTTPS + reverse proxy (Let's Encrypt / self-signed) | [web-server-self-managed.md](self-managed/web-server-self-managed.md) |
| aws-native | S3 · CloudFront · ACM | [web-server-aws-native.md](aws-native/web-server-aws-native.md) |

**Docker equivalent:** Nginx official image — [`containerize-your-infra/modules/web-server`](https://github.com/Bios-Mod/containerize-your-infra/tree/main/modules/web-server)