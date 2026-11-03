# Jira catalog synchronization

`Sync-JiraCatalog.ps1` validates, backs up, plans, and idempotently synchronizes the canonical `platform_contracts/docs/jira/jira-catalog.v1.2.json` catalog.

```powershell
./scripts/jira/Sync-JiraCatalog.ps1 -Mode Validate
./scripts/jira/Sync-JiraCatalog.ps1 -Mode DryRun
./scripts/jira/Sync-JiraCatalog.ps1 -Mode Apply
./scripts/jira/Sync-JiraCatalog.ps1 -Mode DryRun # must be zero diff
```

The credential file is a local PowerShell CLIXML object with `Site`, `Email`, and encrypted `ApiToken` properties. It belongs in `D:\Vistay\.secrets\jira-api.xml` and must never be committed.

Safety properties:

- every non-validation run writes a full pre-change snapshot under `.backups/jira/sync`;
- `Source-ID` is the stable identity;
- no issue/comment deletion and no workflow transition;
- completed historical issues are not rewritten;
- comments are added once when catalog v1.2 first manages an open issue;
- dependency links are added only when absent;
- a second dry run must produce no create/update/link action.
