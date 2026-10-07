import re, sys

p = sys.argv[1]
s = open(p).read()
s2 = re.sub(
    r'(CODE_SIGN_STYLE = Automatic;)',
    r'\1\n\t\t\t\tDEVELOPMENT_TEAM = S123456789;',
    s,
)
open(p, 'w').write(s2)
print('injected DEVELOPMENT_TEAM')
