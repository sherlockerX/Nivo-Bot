# iOS provider-save verification

This repair targets the 2.0.6 maintenance branch. Adding a custom provider was reported to fail
with a file-format error. Tests reproduced the same Cocoa error 259 when checking and recovering
an older SQLite snapshot. The first-save transaction passed on Windows, then failed on macOS
with the same error: Apple SQLite retained a snapshot's shared-memory file after switching to
DELETE journal mode. This provides an Apple-platform reproduction of the persistence failure;
the full custom-provider UI flow still requires an iPhone retest.

## Confirmed defects and repairs

- A read-only check of a WAL snapshot can create companion files that the old recovery manifest
  rejects. New snapshots are sealed as single files. Their destination connection must close
  successfully and the file header must confirm DELETE mode before capture removes its own
  residual auxiliary files. Capture refuses a preexisting destination or companion file, including
  directories and dangling symlinks. Older snapshots accept only the exact WAL/SHM
  companions of registered SQLite payloads and retain committed WAL records during recovery.
- A custom-model ID edit looked up the original record by its new ID. It now finds the record by
  UUID, rejects ID conflicts within the provider, and updates group, conversation and agent references.
- Model forms and new-group forms returned before persistence finished. They now await SQLite and
  JSON writes and retain input on failure. Compensation uses the submitted candidate as its baseline
  so a concurrent failed save cannot leave a model from an unsuccessful submission behind.
- Model-list refreshes now check the source provider and restore generation before publishing.
- Legacy capability enrichment preserves model UUIDs and edit timestamps. Group deletion clears
  voice selections pointing to the group.
- Resetting an unknown context window clears the previous input. Name and ID edits preserve
  unedited reasoning tiers, thinking limits and dedicated speech/video input and output directions.
- Provider-save errors include a diagnostic stage code without sensitive data. Original failures
  and rollback failures are logged separately.

## Verification scope

Portable tests use real temporary files and SQLite to exercise snapshot validation, transaction
boundaries, WAL recovery, identity conflicts and reference remapping. Apple-hosted integration
tests additionally cover the real ProviderConfigStore and ProviderConfigDB, including compensation
and retry after a database write succeeds but the JSON mirror fails.

Windows cannot execute the Apple-hosted tests. The GitHub device build and test-target compilation
also do not mean those hosted tests have run. These checks do not connect to real model providers
or read user credentials.

## iPhone acceptance steps

1. Sign the repaired IPA with the same identity and install it over the existing app to retain data.
2. Open model settings and add a custom provider with your own endpoint and credentials. Confirm
   it appears once. Restart the app and check that the endpoint and model settings remain.
3. Add a custom model, reopen its editor and change its ID to an unused ID. Check that model groups
   still reference it.
4. Add a second model under the same provider and try assigning its ID to the first model. The app
   should report a conflict and keep both original models.
5. Create a group, choose it for voice input or output, then delete it. The selection should clear.
6. Refresh the model list. Loading should be visible; network failure should preserve the current
   configuration and show an error.
7. Send a message using your configured model to verify the real API connection.
8. Rename a speech or video model and check that its capabilities stay the same. Reset a model
   whose base context window is unknown, save again, and confirm the old override does not return.
9. If saving still fails, record the full `PV-` code and whether the action was provider creation,
   key editing, JSON import or model editing. Do not include your API key.

## Diagnostic codes

`PV-stage-errorCode` identifies the failure boundary. Stages are `01` for loading the baseline,
`02` for validating the candidate, `03` for the rollback snapshot, `04` for preparing the journal,
`05` for credentials, `06` for writing configuration, `07` for commit cleanup and `08` for rollback.
The suffix is the NSError bridge code; for a Swift error it is not necessarily the SQLite or
Keychain status. Recovery material remains available after recovery fails. Do not uninstall the
app or delete its database to bypass a recovery error.
