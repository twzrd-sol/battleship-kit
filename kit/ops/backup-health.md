# Backup health

A nightly dump to object storage is only a backup if something independent
reads the bucket back and can say "the newest object is N hours old and
complete".

Pattern:

- The dump job runs from an *attended* checkout that refuses if its own script
  is dirty there.
- A separate read-only timer lists the bucket, classifies keys by age and
  completeness, and exits 0 healthy, 1 on a finding, 2 when it cannot attest.
  Both 1 and 2 page. An unparseable key is a finding, not a traceback.
- Verify by object AGE, not by job exit status. A job that succeeds against the
  wrong database uploads three-migration-old numbers as current, and nothing
  alerts.
- The restore recipe names the exact prefix. An old prefix from a dead host will
  still be there and will restore the wrong corpus.
- Multipart uploads have a part limit; compute part size from the dump size and
  warn well before the limit.
