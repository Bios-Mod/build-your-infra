# Contributing to multi-lab

This lab is designed as a modular, community-usable reference. Contributions that improve clarity, correctness, or coverage are welcome.

---

## How to contribute

**Reporting issues**
Open a GitHub Issue describing:
- Which step or config file is affected
- What the current behaviour is and what you expected
- Your deployment context (VM, bare metal, or VPS) and architecture (ARM64 or x86_64)

**Suggesting improvements**
Open a GitHub Issue before submitting a PR for significant changes — a brief discussion avoids duplicated effort and keeps the lab coherent.

**Submitting a pull request**
1. Fork the repository and create a branch from `main`
2. Keep changes focused — one fix or addition per PR
3. Follow the existing style in `docs/` and `configs/`:
   - Config files include a header block with at minimum:
     ```
     # Deploy to : <target path on server>
     # Apply     : <reload/restart command>
     # Perms     : <chmod command if non-default>
     ```
   - Doc sections follow the `What was done / Why / Verification` structure
   - Commands are copy-pasteable and tested
   - Inline comments explain *why*, not just *what*
4. If adding a new service module, open an Issue first to align on scope

---

## What is in scope

- Corrections to existing steps (commands, paths, parameter values)
- Clarifications to existing documentation
- Additional verification commands for existing steps
- Platform-specific notes (VPS provider differences, alternative architectures)

## What is out of scope

- New service modules (planned in the roadmap — contact via Issue first)
- Automation scripts (planned for a future phase — see the service deployment order in README.md)
- GUI-based tools or non-CLI approaches

---

## Code of conduct

Be direct and technical. Criticism of the work is welcome; criticism of the person is not.
