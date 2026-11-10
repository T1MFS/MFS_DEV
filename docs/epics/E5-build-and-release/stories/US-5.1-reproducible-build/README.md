# US-5.1 Reproducible build

[← E5 Build and release](../../README.md)

**As a** maintainer, **I want** builds to use only pinned versions **so that** nothing changes without a reviewed commit.

**Acceptance:** Submodules pinned to Loop's commits; builds never resolve packages; a separate manual workflow reports available updates.

## Tasks
- [T-5.1.1 Pin submodules and packages](tasks/T-5.1.1-pin-dependencies.md)
- [T-5.1.2 Manual dependency update check](tasks/T-5.1.2-dependency-check.md)
