#!/usr/bin/env python3
"""Mutation check: could your tests have failed?

    mutate.py [--jobs N] [--sample N] [--seed S] [--timeout SECONDS] [--report FILE] [--list]
              <script>[:<sections>]... -- <test command>

For each line of each script it makes ONE small change (flip a comparison, swap && and ||, turn an
`exit 1` into `exit 0`, delete a statement), copies the repository to a scratch directory, applies
the change there, and runs the test command in that copy. A mutant is KILLED when the tests fail
(or hang), and SURVIVED when they still pass. A survivor is either an equivalent change that no test
could notice, or behaviour nothing checks. The second kind is a bug waiting for a quiet day.

Only code is mutated: text inside quotes and comments, docstrings and here-documents (other than
Python in a <<'PY' one) are left alone. A mutant that does not parse (bash -n, a Python compile, awk)
is INVALID and left out of the counts. A deleted line that only prints a message is labelled
(message), so a reviewer can tell wording from behaviour. Lines between "# mutate:off" and
"# mutate:on" are skipped: use that for a script's own self-test, which a test of the script cannot
check (weakening a self-test leaves it passing).

Each mutant runs in a fresh clone of the repository with the working tree's changes copied over, in
its own process group, so a mutant that loops forever is killed with everything it started. The test
command runs with KIT_TEST_FAILFAST=1, so a killed mutant stops at its first failing check, and a
script may name the test sections that exercise it (premerge-check.sh:premerge,parser); they are
passed in KIT_TEST_SECTIONS, which test.sh understands. The unmodified tests run first, once per
section list, and size each mutant's timeout. --list prints the mutants and runs nothing.
Scripts: shell (.sh or extensionless), .py, .awk. Exit 0 when the run completes, whatever survived: the
report is the result. Exit 1 on a usage error or when the unmodified tests do not pass.
"""
import argparse, ast, concurrent.futures, io, os, random, re, shutil, signal, subprocess, sys, tempfile, time, tokenize

SH_TEST_OPS = [(" = ", " != "), (" == ", " != "), (" != ", " == "), (" -eq ", " -ne "), (" -ne ", " -eq "), (" -gt ", " -le "),
               (" -ge ", " -lt "), (" -lt ", " -ge "), (" -le ", " -gt "), (" -z ", " -n "), (" -n ", " -z ")]   # inside [ ] or [[ ]] only
SH_CODE_OPS = [("&&", "||"), ("||", "&&"), ("if ! ", "if "), ("exit 1", "exit 0"), ("exit 2", "exit 0"), ("exit 0", "exit 1"),
               ("return 1", "return 0"), ("return 2", "return 0"), ("fail=1", "fail=0")]
AWK_OPS = [(" == ", " != "), (" != ", " == "), ("&&", "||"), ("||", "&&"), (" > ", " <= "), (" < ", " >= ")]
PY_TOKEN_OPS = {"==": "!=", "!=": "==", "<": ">=", ">": "<=", "<=": ">", ">=": "<", "and": "or", "or": "and", "not": "", "True": "False", "False": "True"}
SKIP_DELETE = re.compile(r"^\s*(if|elif|else|fi|for|while|until|do|done|case|esac|then|function|\{|\}|set -|#!|;;|in\b)")
MESSAGE = re.compile(r"^\s*(echo|printf)\b[^;&|<>]*(>&2)?\s*$")

def code_mask(line):
    """One bool per character: True where the character is shell or awk code, not a quoted string or a comment."""
    mask = [True] * len(line); q = None; i = 0
    while i < len(line):
        ch = line[i]
        if q:
            mask[i] = False
            if ch == "\\" and q == '"' and i + 1 < len(line): mask[i + 1] = False; i += 1
            elif ch == q: q = None
        elif ch in "\"'": q = ch; mask[i] = False
        elif ch == "\\" and i + 1 < len(line): i += 1
        elif ch == "#" and (i == 0 or line[i - 1] in " \t;"):
            for k in range(i, len(line)): mask[k] = False
            break
        i += 1
    return mask

def regions(path, lines):
    """Per line: 'sh' | 'py' | 'awk' | None (not to be mutated)."""
    ext = os.path.splitext(path)[1]
    base = "py" if ext == ".py" else "awk" if ext == ".awk" else "sh"
    lang = [base] * len(lines); off = False
    for i, l in enumerate(lines):
        if "mutate:off" in l: off = True
        if off: lang[i] = None
        if "mutate:on" in l: off = False
    i = 0
    while i < len(lines) and base == "sh":
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_]+)['\"]?", lines[i])
        if m and "<<<" not in lines[i]:
            tag = m.group(1); j = i + 1
            while j < len(lines) and lines[j].strip() != tag: j += 1
            for k in range(i + 1, min(j, len(lines))):
                if lang[k] is not None: lang[k] = "py" if tag == "PY" else None
            if j < len(lines): lang[j] = None   # the terminator is syntax, not behaviour: deleting it swallows the rest of the file
            i = j
        i += 1
    return [None if (lang[i] is None or not l.strip() or (lang[i] != "py" and l.lstrip().startswith("#"))) else lang[i] for i, l in enumerate(lines)]

def py_mutants(src):
    """(zero-based line, new source, description) for a Python source text."""
    lines = src.split("\n"); out = []
    toks = [t for t in tokenize.generate_tokens(io.StringIO(src).readline) if t.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.COMMENT, tokenize.INDENT, tokenize.DEDENT)]
    for i, t in enumerate(toks):
        (r1, c1), (r2, c2) = t.start, t.end
        if r1 != r2: continue
        rep = None
        if t.type in (tokenize.OP, tokenize.NAME) and t.string in PY_TOKEN_OPS: rep = PY_TOKEN_OPS[t.string]
        elif t.type == tokenize.NUMBER and t.string in ("1", "2") and i > 0 and (toks[i - 1].string == "return" or (toks[i - 1].string == "(" and i > 3 and toks[i - 2].string == "exit" and toks[i - 3].string == ".")): rep = "0"
        if rep is None: continue
        new = lines[:]; new[r1 - 1] = lines[r1 - 1][:c1] + rep + lines[r1 - 1][c2:]
        out.append((r1 - 1, "\n".join(new), "%s -> %s" % (t.string, rep or "(removed)")))
    kinds = (ast.Assign, ast.AugAssign, ast.AnnAssign, ast.Expr, ast.Return, ast.Raise, ast.Delete, ast.Assert)
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, kinds): continue
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str): continue   # a docstring
        new = lines[:]
        for k in range(node.lineno - 1, node.end_lineno): new[k] = ""
        out.append((node.lineno - 1, "\n".join(new), "delete the statement"))
    return out

def shell_line_mutants(l, ops_test, ops_code):
    mask = code_mask(l); out = []
    for pat, rep in ops_code:
        for m in re.finditer(re.escape(pat), l):
            if all(mask[m.start():m.end()]) and (pat[0] not in "if" or m.start() == 0 or not l[m.start() - 1].isalnum()):
                out.append((l[:m.start()] + rep + l[m.end():], "%s -> %s" % (pat.strip(), rep.strip()))); break
    for pat, rep in ops_test:
        for m in re.finditer(re.escape(pat), l):
            pre = [c for c, k in zip(l[:m.start()], mask) if k]
            if all(mask[m.start():m.end()]) and pre.count("[") > pre.count("]"):
                out.append((l[:m.start()] + rep + l[m.end():], "%s -> %s" % (pat.strip(), rep.strip()))); break
    return out

def mutants(path):
    """[(1-based line, full new source, description)] for every mutant that parses."""
    text = open(path).read(); lines = text.split("\n"); lang = regions(path, lines); out = []
    ext = os.path.splitext(path)[1]
    if ext == ".py":
        found = py_mutants(text)
        cands = [(n, src, why) for n, src, why in found if lang[n] is not None]
    else:
        cands = []
        for n, l in enumerate(lines):
            if lang[n] in ("sh", "awk"):
                ops = shell_line_mutants(l, SH_TEST_OPS if lang[n] == "sh" else [], SH_CODE_OPS if lang[n] == "sh" else [])
                if lang[n] == "awk":
                    mask = code_mask(l)
                    for pat, rep in AWK_OPS:
                        for m in re.finditer(re.escape(pat), l):
                            if all(mask[m.start():m.end()]): ops.append((l[:m.start()] + rep + l[m.end():], "%s -> %s" % (pat.strip(), rep.strip()))); break
                for newline, why in ops: cands.append((n, "\n".join(lines[:n] + [newline] + lines[n + 1:]), why))
                cont = n > 0 and lines[n - 1].rstrip().endswith(("\\", "&&", "||", "|", "(", "{"))
                if not SKIP_DELETE.match(l) and not l.rstrip().endswith(("\\", "&&", "||", "|", "(", "{", "<<")) and "<<" not in l and not cont and not re.match(r"^\s*\w+\(\)", l):
                    cands.append((n, "\n".join(lines[:n] + [""] + lines[n + 1:]), "delete the line" + (" (message)" if MESSAGE.match(l) else "")))
        # Python inside a <<'PY' heredoc: mutate the body as Python, then put it back
        n = 0
        while n < len(lines):
            if lang[n] == "py":
                a = n
                while n + 1 < len(lines) and lang[n + 1] == "py": n += 1
                body = "\n".join(lines[a:n + 1])
                try:
                    for k, src, why in py_mutants(body):
                        cands.append((a + k, "\n".join(lines[:a] + src.split("\n") + lines[n + 1:]), why + " (python)"))
                except SyntaxError: pass
            n += 1
    seen = set()
    for n, src, why in cands:
        if src == text or (n, src) in seen: continue
        seen.add((n, src))
        if parses(path, src, lines, lang, n): out.append((n + 1, src, why))
    return out

def parses(path, src, lines, lang, n):
    ext = os.path.splitext(path)[1]
    try:
        if ext == ".py": compile(src, path, "exec"); return True
        if lang[n] == "py":   # python in a heredoc: compile just that body
            new = src.split("\n"); a = n
            while a > 0 and lang[a - 1] == "py": a -= 1
            b = n
            while b + 1 < len(lang) and lang[b + 1] == "py": b += 1
            shift = len(new) - len(lines)
            compile("\n".join(new[a:b + 1 + shift]), path, "exec")
        with tempfile.NamedTemporaryFile("w", suffix=ext, delete=False) as f: f.write(src); tmp = f.name
        try:
            cmd = ["awk", "-f", tmp, "/dev/null"] if ext == ".awk" else ["bash", "-n", tmp]
            return subprocess.run(cmd, capture_output=True, timeout=20).returncode == 0
        finally: os.unlink(tmp)
    except (SyntaxError, ValueError, subprocess.TimeoutExpired, tokenize.TokenError):
        return False

def copy_tree(root, files, dest):
    """A clone (the tests may need history) with the working tree's changes laid over it."""
    subprocess.run(["git", "clone", "-q", "--local", "--no-hardlinks", root, dest], check=True, capture_output=True)
    for gone in subprocess.check_output(["git", "-C", root, "ls-files", "--deleted", "-z"], text=True).split("\0"):
        if gone and os.path.exists(os.path.join(dest, gone)): os.unlink(os.path.join(dest, gone))
    for f in files:
        d = os.path.join(dest, f); os.makedirs(os.path.dirname(d), exist_ok=True)
        if os.path.islink(os.path.join(root, f)): continue
        shutil.copy2(os.path.join(root, f), d)

def run_mutant(root, files, path, src, cmd, timeout, sections):
    with tempfile.TemporaryDirectory(prefix="mutant.") as dest, tempfile.TemporaryDirectory(prefix="mutant-tmp.") as scratch:
        copy_tree(root, files, dest)
        with open(os.path.join(dest, path), "w") as f: f.write(src)
        os.chmod(os.path.join(dest, path), os.stat(os.path.join(root, path)).st_mode)
        env = dict(os.environ, KIT_TEST_FAILFAST="1", TMPDIR=scratch)   # scratch space outside the copy: tests that scan the tree must not read it
        if sections: env["KIT_TEST_SECTIONS"] = sections
        # Its own session, so a mutant that loops forever is killed with every process it started.
        proc = subprocess.Popen(["nice", "-n", "15", *cmd], cwd=dest, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            rc = None   # a hang is a failure the tests noticed: killed
        finally:
            try: os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError): pass
            proc.wait()
        return "survived" if rc == 0 else "killed"

def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--jobs", type=int, default=4); ap.add_argument("--sample", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=0, help="seconds per mutant; default 4 x the unmodified run of the same sections, at least 60")
    ap.add_argument("--report", default=""); ap.add_argument("--list", action="store_true", help="print the mutants and run nothing")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    if "--" not in a.rest: sys.exit("usage: mutate.py [options] <script>[:<sections>]... -- <test command>")
    k = a.rest.index("--"); specs, cmd = a.rest[:k], a.rest[k + 1:]
    if not specs or not cmd: sys.exit("usage: mutate.py [options] <script>[:<sections>]... -- <test command>")
    scripts = [(x.split(":", 1)[0], x.split(":", 1)[1] if ":" in x else "") for x in specs]
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip(); os.chdir(root)
    jobs = []
    for path, sections in scripts:
        for line, src, why in mutants(path): jobs.append((path, line, why, open(path).read().split("\n")[line - 1].strip()[:90], src, sections))
    if a.list:
        for p, n, w, l, _, _ in jobs: print("%s:%d  %s    | %s" % (p, n, w, l))
        print("%d mutants" % len(jobs)); return
    files = [f for f in subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], text=True).split("\0") if f and os.path.isfile(f)]
    limits = {}   # test sections -> seconds a mutant may take before it counts as a hang
    for sections in sorted({sec for _, sec in scripts}):
        label = sections or "(all)"
        print("baseline: running the unmodified tests, sections %s ..." % label, flush=True)
        with tempfile.TemporaryDirectory(prefix="mutant.") as dest, tempfile.TemporaryDirectory(prefix="mutant-tmp.") as scratch:
            copy_tree(root, files, dest)
            env = dict(os.environ, KIT_TEST_FAILFAST="1", TMPDIR=scratch)
            if sections: env["KIT_TEST_SECTIONS"] = sections
            t0 = time.time(); base = subprocess.run(cmd, cwd=dest, env=env, capture_output=True); took = time.time() - t0
        if base.returncode != 0: sys.exit("the unmodified tests do not pass for sections %s; a mutation run means nothing until they do" % label)
        limits[sections] = a.timeout or max(60, int(4 * took))
    random.Random(a.seed).shuffle(jobs)
    if a.sample: print("sampling %d of %d valid mutants (seed %d)" % (min(a.sample, len(jobs)), len(jobs), a.seed)); jobs = jobs[:a.sample]
    print("%d valid mutants; running with %d jobs" % (len(jobs), a.jobs), flush=True)
    results = {"killed": 0, "survived": 0}; survivors = []
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        futs = {ex.submit(run_mutant, root, files, p, s, cmd, limits[sec], sec): (p, n, w, l) for p, n, w, l, s, sec in jobs}
        for i, f in enumerate(concurrent.futures.as_completed(futs), 1):
            r = f.result(); results[r] += 1
            if r == "survived": survivors.append(futs[f])
            if i % 25 == 0: print("  %d/%d done, %d survived so far" % (i, len(jobs), len(survivors)), flush=True)
    survivors.sort(key=lambda t: (t[0], t[1]))
    total = results["killed"] + results["survived"]
    out = ["mutants: %d valid, %d killed, %d survived (%.0f%% killed)" % (total, results["killed"], results["survived"], 100.0 * results["killed"] / total if total else 0.0)]
    out += ["SURVIVED %s:%d  %s    | %s" % (p, n, w, l) for p, n, w, l in survivors]
    print("\n".join(out))
    if a.report: open(a.report, "w").write("\n".join(out) + "\n")

if __name__ == "__main__":
    main()
