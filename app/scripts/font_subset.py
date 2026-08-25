# 从应用源码提取实际用到的字符,生成 Noto Sans SC 子集(woff2)。
import os
from fontTools import subset

text = ''
for root, dirs, files in os.walk('lib'):
    for f in files:
        if f.endswith('.dart'):
            with open(os.path.join(root, f), encoding='utf-8', errors='ignore') as fh:
                text += fh.read()

# 常见 ASCII + 中英文标点 + 数字。
extra = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ .,:;!?+-*/=()[]{}<>@#%&^_~|\\"\'`\u00b7\u3001\u3002\uff0c\uff01\uff1f\uff1a\uff1b\uff08\uff09\u3010\u3011\u300a\u300b\u300c\u300d\u201c\u201d\u2026\u2014\u2013'
text += extra

chars = sorted(set(ch for ch in text if ord(ch) >= 0x20))
print(f'source chars: {len(chars)}')

# 追加常用 3500 汉字(覆盖用户动态输入的资产名/分组名/提醒内容)。
# 取 CJK 基本区高频字——简化:U+4E00-U+9FA5 的前 3500 个。
common = set(range(0x4E00, 0x4E00 + 3500))
chars = sorted(set(chars) | set(chr(cp) for cp in common))
print(f'total chars: {len(chars)}')

options = subset.Options()
options.flavor = 'woff2'
options.layout_features = ['*']
font = subset.load_font('assets/fonts/noto.ttf', options)
subsetter = subset.Subsetter(options=options)
subsetter.populate(text=''.join(chars))
subsetter.subset(font)
font.save('assets/fonts/noto_subset.woff2')
print('done')