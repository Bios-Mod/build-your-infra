# File Transfer

Controlled file transfer with enforced authentication, session isolation, and access scope restriction.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed
on the target environment before applying this module.

## Implementations

| Environment | Technology | Status | Doc |
|---|---|---|---|
| self-managed | SFTP (OpenSSH internal subsystem) | Complete | [self-managed.md](self-managed/self-managed.md) |
| aws-native | AWS Transfer Family (SFTP / FTPS / FTP) | Planned | [aws-native.md](aws-native/aws-native.md) |