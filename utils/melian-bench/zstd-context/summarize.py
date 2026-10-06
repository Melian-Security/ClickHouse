import statistics as st, collections, sys
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1]) if l.strip()]
d = collections.defaultdict(list)
for r in rows:
    d[(r[1], r[0])].append(r)
cols = {'merge_ms': 8, 'm_user_ms': 9, 'm_sys_ms': 10, 'merge_proc_cpu_s': 15, 'ins_us/row': 4, 'ins_sys_us/row': 5,
        'ins_proc_cpu_s': 7, 'hwm_final_MiB': 17, 'samples': 19, 'madv': 20, 'freeCCtx': 21}
med = {}
for (m, b), rs in sorted(d.items()):
    out = []
    for k, i in cols.items():
        x = sorted(float(r[i]) for r in rs)
        med[(m, b, k)] = st.median(x)
        out.append(f"{k}={st.median(x):.1f}[{x[0]:.0f}-{x[-1]:.0f}]")
    x = sorted(float(r[9]) + float(r[10]) for r in rs)
    med[(m, b, 'merge_cpu')] = st.median(x)
    out.append(f"merge_cpu(u+s)={st.median(x):.0f}[{x[0]:.0f}-{x[-1]:.0f}]")
    print(m, b, len(rs), ' '.join(out))
    print('   hashes', set(r[18] for r in rs))
for m in sorted(set(k[0] for k in d)):
    if (m, 'base', 'merge_ms') in med and (m, 'fix', 'merge_ms') in med:
        print(m, ' '.join(f"{k}:{100 * (med[(m, 'fix', k)] / med[(m, 'base', k)] - 1):+.1f}%"
                          for k in ['merge_ms', 'merge_cpu', 'm_user_ms', 'm_sys_ms', 'merge_proc_cpu_s', 'ins_us/row', 'ins_proc_cpu_s']))
