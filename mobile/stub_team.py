#!/usr/bin/env python3
"""向 iOS pbxproj 注入占位 DEVELOPMENT_TEAM，骗过 Xcode "Development Team not selected"。

原逻辑用 regex `CODE_SIGN_STYLE = Automatic;` 匹配，新 runner 上 Flutter 生成的 pbxproj
里 Runner target 根本没有这行（只有 Tests target 有），导致注入静默不命中。
新方案直接按 Runner 的 PRODUCT_BUNDLE_IDENTIFIER 段匹配，往段尾塞一行。
"""
import re, sys

p = sys.argv[1]
s = open(p).read()

# Team ID 必须是 10 位大写字母数字、首字母（Apple 格式要求）
FAKE_TEAM = 'XXXXXXXXXX'
RUNNER_BUNDLE = 'cn.ruanftrix.sylphplayMobile'
TEST_BUNDLE   = 'cn.ruanftrix.sylphplayMobile.RunnerTests'

count = 0
lines = s.split('\n')
out = []
i = 0
while i < len(lines):
    line = lines[i]
    out.append(line)

    # 找到 Runner 或 Tests target 的 PRODUCT_BUNDLE_IDENTIFIER 行
    m = re.match(r'(\s*)PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(' + re.escape(RUNNER_BUNDLE) + r'|' + re.escape(TEST_BUNDLE) + r');', line)
    if m:
        indent = m.group(1)
        bundle = m.group(2)
        # 在这个段里找是否已经有 DEVELOPMENT_TEAM
        j = i + 1
        has_team = False
        while j < len(lines):
            if lines[j].strip().endswith(';') and not lines[j].startswith(indent + '\t') and not lines[j].startswith(indent + '\t\t'):
                break
            if re.search(r'DEVELOPMENT_TEAM\s*=', lines[j]):
                has_team = True
                break
            j += 1
        if not has_team:
            out.append(f'{indent}\t\t\t\tDEVELOPMENT_TEAM = {FAKE_TEAM};')
            count += 1

    i += 1

open(p, 'w').write('\n'.join(out))
print(f'injected DEVELOPMENT_TEAM={FAKE_TEAM} into {count} target(s)')
