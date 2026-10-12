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
    'FSBGestureForwarder',
    'fsbHandlePan:',
    'pan.state != UIGestureRecognizerStateEnded',
    '[nav popViewControllerAnimated:YES]',
    'initWithTarget:[FSBGestureForwarder shared]',
    '@catch (id e)',
]
for kw in keys:
    print(('OK  ' if kw in src else 'MISS'), kw)

# 已删除项必须不存在
gone = ['FSBGoHome', 'gFSBInTransition', 'gFSBLastPopAt', 'FSBTransitionTarget', 'FSBHandleTransitionSEL', 'handleNavigationTransition', 'exit(']
for kw in gone:
    print(('CLEAN' if kw not in src else 'LEFTOVER!!'), kw)

print('TOTAL:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
