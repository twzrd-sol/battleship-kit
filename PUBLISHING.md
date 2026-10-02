# Publishing this kit

Do not flip this repository's visibility. Publish a snapshot.

A repo that goes public publishes every commit it ever had. This kit's source
repository was private first, and before it was fixed its commits tracked the
denylist that names the internal things the kit must never mention (see
`INCIDENTS.md`). A snapshot has no past to leak, so that is what gets published,
and the same rule holds for anything you take from a repository whose history you
cannot vouch for.

1. Keep your identifiers in a local list, never in the repo:
   `~/.config/battleship-kit/denylist.txt` (mode 0600), one `grep -E` pattern per
   line: private repo names, hostnames, buckets, people, vendors under embargo.
   `denylist.generic.txt` covers the shapes (emails, 32-byte addresses and
   64-byte secret keys, private ranges, credential and token formats, passwords in
   URLs, home directories). `scan.sh` refuses to run without a local list (exit 2)
   unless you set `KIT_ALLOW_GENERIC_ONLY=1`, which checks the generic shapes
   only and says so; the exporter refuses to run with that variable set. Keep a
   backup of the local list; it is the only copy.
2. Read `ESSAY.md`. It speaks in the first person: it states revenue, hosting,
   and what the author did and did not do. Be sure every statement in it is
   yours before you publish.
3. `./test.sh` must say `RESULT: all passed`. `scan.sh` also refuses what a text
   scan cannot read: binary files, files that are not valid UTF-8, invisible and
   direction-changing characters, symbolic links, submodules, a sparse checkout,
   and a `.gitattributes` that changes how git stores or exports files; and in
   history, signed commits and tags, commit headers beyond the standard four, and
   refs that point at something that is not a commit. This kit ships text only.
4. Know what the gate cannot see. It is a safer way to publish, not a proof. It
   does not decode: base64, rot13, percent-encoding and HTML entities of a listed
   name pass. It reads lines: a name wrapped across two lines, or split by a
   separator you did not list, passes. Look-alike letters pass. It knows only the
   shapes and names on its lists, so a public IP address, a domain or a person you
   never listed passes. Reflogs and objects no ref reaches are not read, because
   they are not published.
5. `./export-public.sh --identity "<Name> <your GitHub noreply address>" <new-dir>`
   builds a one-commit snapshot of HEAD, then runs the tree scan, the history scan
   (which also reads commit headers, tags, ref names and file names), and the
   snapshot's own `test.sh` inside it, and checks that the snapshot's tree is
   identical to HEAD. It names the source commit and tree it was built from; add
   `--head <rev>` to refuse unless HEAD is the commit you reviewed. The snapshot
   commit is public, so its identity is explicit, and it is never signed: an
   ambient git identity that is not a noreply address is refused, and so is a
   signing configuration's effect. Set `KIT_EXPORT_MESSAGE` for the commit subject
   (the default is `public snapshot`) and `KIT_EXPORT_TRAILER` to add a trailer
   line, such as a Co-Authored-By. It refuses to run while `KIT_ALLOW_BINARY` or
   `KIT_ALLOW_GENERIC_ONLY` is set, never pushes, and needs a `test.sh` in the
   snapshot (`KIT_EXPORT_NO_TEST=1` skips that for a repo without one).
6. Publish the snapshot, not this repo, with the one command the exporter prints.
   Pass `--repo owner/name` to the exporter, or set `REPO=owner/name` yourself;
   the command refuses to run without it. It stops unless the snapshot is still
   exactly the commit it built, with a clean tree, scans it again with your local
   list required, and only then publishes.
   Nothing in the snapshot is to be edited; if you change anything, change the
   source, commit, and export again into a new directory.

Chain steps with `&&`. A pipe or `;` between a gate and the publish publishes
on a failure.
