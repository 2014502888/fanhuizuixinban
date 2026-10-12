# -*- coding: utf-8 -*-
import re, sys

p = r'C:\Users\Administrator.DESKTOP-DC1E8KC\Documents\deepseek-harness\default-workspace\FullScreenBack\actions\FullScreenBackUniversal.m'
src = open(p, encoding='utf-8').read()
s = re.sub(r'//[^\n]*', '', src)
s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
s = re.sub(r'@"(?:[^"\\]|\\.)*"', '""', s)

ok = True
for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
    ca, cb = s.count(a), s.count(b)
    print('%s=%d %s=%d %s' % (a, ca, b, cb, 'OK' if ca == cb else 'MISMATCH'))
    if ca != cb:
        ok = False

keys = [
    'FSBGestureForwarder', 'fsbHandlePan:', 'FSBGoHome',
    'gFSBInTransition', 'gFSBLastPopAt',
    'initWithTarget:[FSBGestureForwarder shared]',
    '@catch (id e)', '#include <stdlib.h>',
    'static id FSBTransitionTarget(UINavigationController *nav);',
    'dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC))',
    'SEL handle = FSBHandleTransitionSEL();',
]
for kw in keys:
    print(('OK  ' if kw in src else 'MISS'), kw)

print('TOTAL:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
