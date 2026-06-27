import sys, re
app, dp, path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split('\n')
idxs = [i for i, l in enumerate(lines) if re.match(r'  [A-Za-z0-9_-]+:\s*$', l)]
idxs.append(len(lines))
for j in range(len(idxs) - 1):
    s, e = idxs[j], idxs[j + 1]
    cn = None
    for k in range(s, e):
        m = re.search(r'container_name:\s*' + re.escape(app) + r'-(int|prod)-(blue|green)\b', lines[k])
        if m:
            cn = f"{m.group(1)}-{m.group(2)}"
            break
    if not cn:
        continue
    for k in range(s, e):
        if re.match(r'\s*image:\s*' + re.escape(app) + r':', lines[k]):
            lines[k] = re.sub(r'image:\s*\S+', 'image: plaintext-runtime:jre25', lines[k])
        elif re.search(r'/logs:/app/logs\s*$', lines[k]):
            ind = lines[k][:len(lines[k]) - len(lines[k].lstrip())]
            lines[k] = lines[k] + f"\n{ind}- {dp}/jars/{cn}/app.jar:/app/app.jar:ro"
open(path + '.m3', 'w').write('\n'.join(lines))
