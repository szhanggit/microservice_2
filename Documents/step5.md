Setup branch protection and PR templates:

1. Branch protection:
   - develop: 1 approval required
   - staging: 2 approvals required
   - master: 2 approvals + staging deployment verification

2. PR template with:
   - Change description
   - Test steps
   - Impact analysis

3. Version tagging:
   - Auto-tag on staging and prod merges