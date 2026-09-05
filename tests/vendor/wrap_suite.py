#!/usr/bin/env python3
"""Generates r7rs-tests-wrapped.scm from the pristine r7rs-tests.scm.

Wraps every top-level form that is not a definition or import in (try ...)
so one failing block cannot abort the rest of the suite. Run from the
repository root after updating the vendored file.
"""
import re

src = open('tests/vendor/r7rs-tests.scm').read()
forms, depth, start, i, n = [], 0, None, 0, len(src)
while i < n:
    c = src[i]
    if c == ';':
        while i < n and src[i] != '\n':
            i += 1
        continue
    if c == '#' and i + 1 < n and src[i + 1] == '|':
        d, i = 1, i + 2
        while i + 1 < n and d:
            if src[i:i + 2] == '#|':
                d, i = d + 1, i + 2
            elif src[i:i + 2] == '|#':
                d, i = d - 1, i + 2
            else:
                i += 1
        continue
    if c == '"':
        j = i + 1
        while j < n and src[j] != '"':
            j += 2 if src[j] == '\\' else 1
        i = j + 1
        continue
    if c == '#' and i + 1 < n and src[i + 1] == '\\':
        i += 3
        continue
    if c == '(':
        if depth == 0:
            start = i
        depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0 and start is not None:
            forms.append(src[start:i + 1])
            start = None
    i += 1

# Route every form through eval so even compile-time errors in one form
# are catchable and cannot abort the rest of the suite.
out = []
for form in forms:
    out.append('(try (eval (quote ' + form + ')) (catch %conf-e (%conf-block-failed %conf-e)))')
open('tests/vendor/r7rs-tests-wrapped.scm', 'w').write('\n'.join(out) + '\n')
print(f'{len(forms)} forms written')
