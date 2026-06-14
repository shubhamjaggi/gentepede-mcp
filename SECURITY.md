# Security Policy

## Supported Versions

This project is under active development. Security fixes are applied to the latest
`main` branch and the most recent release.

| Version | Supported |
|---|---|
| latest `main` | ✅ |
| older tags | ❌ |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, report them privately using either of the following:

1. **GitHub private vulnerability reporting** — open the repository's
   **Security → Report a vulnerability** tab (preferred).
2. **Email** — **shubham.jaggi@gmail.com** with the subject line
   `SECURITY: gentepede-mcp`.

Please include:
- A description of the issue and its impact.
- Steps to reproduce (a minimal blueprint / workspace, if relevant).
- Any suggested remediation.

You can expect an initial acknowledgement within **5 business days**. Once the issue
is confirmed, we will work on a fix and coordinate a disclosure timeline with you.

## Scope Notes

Gentepede MCP generates and orchestrates infrastructure-as-code and runs external
CLIs (terraform, helm, checkov, etc.) on the user's machine. When reporting, it is
especially helpful to flag:

- Generated Terraform or Helm output that is insecure by default.
- Command construction that could allow injection via blueprint variables or
  `project_name`.
- Handling of credentials, plan files, or state backups.

This tool is intended for authorized infrastructure provisioning and security review
only.
