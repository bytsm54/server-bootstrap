---
name: Skill vetting rule
description: Must run skill-vetter before installing any skill from external sources
type: feedback
---

Always run the skill-vetter skill before installing any new skill from ClawHub, GitHub, or other external sources. No exceptions.

**Why:** Security policy — prevent malicious or poorly-written skills from being installed without review.

**How to apply:** Before any `npx skills add` or skill installation, invoke `/skill-vetter` first and get user approval.
