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
    'FSBGestureForwarder', 'fsbHandlePan:', '[nav popViewControllerAnimated:YES]',
    'initWithTarget:[FSBGestureForwarder shared]', '@catch (id e)',
    'SW_NAV_PUSH', 'SW_NAV_SETVCS', 'gSwizzle[4]', 'depth > 64',
]
for kw in keys:
    print(('OK  ' if kw in src else 'MISS'), kw)

gone = [
    'FSBGoHome', 'gFSBInTransition', 'gFSBLastPopAt', 'FSBTransitionTarget',
    'FSBHandleTransitionSEL', 'exit(', 'SW_NAV_VIEWDIDLOAD', 'SW_NAV_VIEWDIDAPPEAR',
    'SW_VC_VIEWDIDAPPEAR', 'FSB_UINavigationController_viewDidLoad',
    'FSB_UINavigationController_viewDidAppear', 'FSB_UIViewController_viewDidAppear',
    'handleNavigationTransition',
]
for kw in gone:
    print(('CLEAN' if kw not in src else 'LEFTOVER!!'), kw)

print('TOTAL:', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
