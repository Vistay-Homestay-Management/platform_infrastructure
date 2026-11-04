# Jira catalog synchronization

`Sync-JiraCatalog.ps1` validates, backs up, plans, and idempotently synchronizes the compiled canonical `platform_contracts/docs/jira/jira-catalog.v1.3.json` catalog.

```powershell
./scripts/jira/Sync-JiraCatalog.ps1 -Mode Validate
./scripts/jira/Sync-JiraCatalog.ps1 -Mode DryRun
./scripts/jira/Sync-JiraCatalog.ps1 -Mode Apply -SourceId VS-E03-T01,VS-E03-S01-ST01
./scripts/jira/Sync-JiraCatalog.ps1 -Mode DryRun -SourceId VS-E03-T01,VS-E03-S01-ST01 # must be zero diff
```

The credential file is a local PowerShell CLIXML object with `Site`, `Email`, and encrypted `ApiToken` properties. It belongs in `D:\Vistay\.secrets\jira-api.xml` and must never be committed.

Safety properties:

- every non-validation run writes a full pre-change snapshot under `.backups/jira/sync`;
- `Source-ID` is the stable identity;
- no issue/comment deletion and no workflow transition;
- completed historical descriptions, statuses, and delivery evidence are not rewritten; missing Module metadata may still be completed from the canonical repository mapping;
- Jira `Module` selections are completed from the catalog `repositories` list by matching allowed option values; existing manual Module selections are preserved and only missing selections are added;
- platform and cross-service repositories map to `Platform Contracts`, `Platform Infrastructure`, and `Cross-service`; synchronization fails closed when a required option does not exist;
- comments are added once when catalog v1.3 first manages an open issue;
- dependency links are added only when absent;
- a second dry run must produce no create/update/link action.

Apply at most five Source-IDs per canary. Full Apply requires explicit `-ConfirmFullApply`; creation additionally requires `-AllowCreates`. The script never changes workflow status unless the separately guarded transition option is explicitly used.
