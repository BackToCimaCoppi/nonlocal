# Security Policy

## Reporting a Vulnerability

Please do **not** open public GitHub issues for security vulnerabilities.

Instead, report security issues privately via **GitHub Security Advisories**:
- https://github.com/BackToCimaCoppi/nonlocal/security/advisories/new

Please include:
- A clear description of the vulnerability and potential impact
- Steps to reproduce (or a minimal proof-of-concept)
- Affected component (`packages/bridge` or `ios`) and version

## Security Model & Boundaries

`nonlocal-bridge` intentionally binds to `127.0.0.1` by default and relies on transport-layer security (such as Tailscale WireGuard, Cloudflare Tunnel, or TLS reverse proxies) for remote access. It does not implement built-in TLS or application-layer E2EE.

For detailed hardening guidance, token handling, non-loopback rate limiting, and network exposure boundaries, see [docs/security.md](docs/security.md).
