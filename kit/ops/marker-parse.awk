# Extract the honesty marker(s) a PR comment or review body can carry.
#
# RULE: a marker is LIVE only when it is the very FIRST LINE of the body and starts at column 0
# with "GATE-REVIEW:". Nothing else in the body is ever read as a marker, with TWO exceptions that
# can only make the check stricter:
#   1. if the first line is a live marker and any LATER line also starts with "GATE-REVIEW:", that
#      line is printed too (a bare carriage return counts as a line break, as it does when GitHub
#      renders). Two markers in one comment are ambiguous, and the merge check refuses them.
#   2. a line that LOOKS like a marker but is not live is reported as STRAY followed by the line
#      (indented, quoted, bold, bulleted, after a byte-order mark, lower case, not the first line, or
#      after any other prefix such as an emoji, a pipe or "Verdict:"). A reviewer who meant a reject
#      and wrote it in the wrong place must not be ignored silently; the merge check refuses until the
#      comment is fixed or deleted, unless every commit id on the line is another full commit.
# A line "looks like a marker" when, after leading indentation, quote and list marks, emphasis and
# digits, it starts with gate-review (any case, hyphen or underscore) and a colon follows; or when
# gate-review and a colon appear ANYWHERE in the line and the text after the colon holds reject,
# approve, block or a run of seven hex characters. A mention in a sentence that says none of those
# is not marker-shaped and is not reported.
# The Unicode line and paragraph separators (U+2028, U+2029) and U+0085 count as line breaks, as a
# bare carriage return does, because other renderers split on them.
#
# Why so strict. A first line cannot be inside a code fence, a quote, an HTML block, an HTML
# comment, a link reference definition, or anything else that opened on an earlier line, so
# there is nothing to model and nothing to forge. Every construct an earlier version of this
# parser tried to model (fences, <pre>, <details>, <!-- -->, blockquote continuations, link
# reference definition titles, processing instructions, CDATA, unterminated tags) was a way to
# forge a marker or to lose one, and each fix surfaced the next. Fail closed instead.
#
# Tolerated: a trailing carriage return (the API returns CRLF bodies). Not tolerated: leading
# blank lines, leading spaces, a byte-order mark, lookalike characters. Lookalike characters
# (a non-breaking hyphen, a Cyrillic letter) are not detected at all: the parser reads ASCII.
# If an HTML comment starts later on the SAME line, only the text before it is visible to a
# reader, so only that text is returned.
#
# Run it with LC_ALL=C: the byte-order mark is matched as three bytes.
function undecorate(s,   c) {
  while (1) {
    c = substr(s, 1, 1)
    if (c == " " || c == "\t" || c == ">" || c == "*" || c == "_" || c == "#" || c == "-" || c == "+" || c == "~" || c == "`" || c == "(" || c == ")" || c == "[" || c == "]" || c == "." || c ~ /^[0-9]$/) s = substr(s, 2)
    else if (substr(s, 1, 3) == "\357\273\277") s = substr(s, 4)
    else break
  }
  return s
}
function marker_like(s,   t, c) {
  t = tolower(undecorate(s))
  c = substr(t, 1, 11)
  if (c != "gate-review" && c != "gate_review") return 0
  t = substr(t, 12)
  while (1) {
    c = substr(t, 1, 1)
    if (c == " " || c == "\t" || c == "*" || c == "_" || c == "`") t = substr(t, 2)
    else break
  }
  return substr(t, 1, 1) == ":"
}
function stray_like(s,   t, off, p, rest) {
  # EVERY mention is examined, not just the first: an earlier harmless "gate-review" in the same
  # sentence must not hide a later "GATE-REVIEW: ... reject ...".
  t = tolower(s)
  off = 0
  while (1) {
    p = match(substr(t, off + 1), /gate[-_]review/)
    if (p == 0) return 0
    off += p + 10
    rest = substr(t, off + 1)
    while (substr(rest, 1, 1) ~ /[ \t*_`]/) rest = substr(rest, 2)
    if (substr(rest, 1, 1) == ":") {
      rest = substr(rest, 2)
      if (rest ~ /reject|approve|block/ || rest ~ /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/) return 1
    }
  }
}
{
  line = $0
  gsub(/\342\200[\250\251]|\302\205/, "\r", line)
  n = split(line, seg, "\r")
  for (k = 1; k <= n; k++) {
    s = seg[k]
    if (NR == 1 && k == 1 && s ~ /^GATE-REVIEW:/) {
      live = 1
      i = index(s, "<!--"); if (i > 0) s = substr(s, 1, i - 1)
      print s
    } else if (live && s ~ /^GATE-REVIEW:/) {
      print s
    } else if (marker_like(s) || stray_like(s)) {
      print "STRAY " s
    }
  }
}
