# File Transfer

Controlled file transfer with enforced authentication, session isolation, and access scope restriction.

**Requires:** [`modules/hardening/`](../hardening/README.md) fully deployed
on the target environment before applying this module.

## Implementations

| Environment | Technology | Doc |
|---|---|---|---|
| self-managed | SFTP (OpenSSH internal subsystem) | [file-transfer-self-managed.md](self-managed/file-transfer-self-managed.md) |
| aws-native | AWS Transfer Family (SFTP / FTPS / FTP) | [file-transfer-aws-native.md](aws-native/file-transfer-aws-native.md) |

**Docker equivalent:** atmoz/sftp — [`containerize-your-infra/modules/file-transfer`](https://github.com/Bios-Mod/containerize-your-infra/tree/main/modules/file-transfer)