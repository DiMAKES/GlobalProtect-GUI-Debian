#!/usr/bin/python3
# Пакет Arch (.pkg.tar.zst) из готового дерева с .PKGINFO/.INSTALL — то же, что делает makepkg,
# но на любой системе. Запуск: mkpkg.py <дерево> <файл.pkg.tar.zst>
import gzip, hashlib, io, os, subprocess, sys, tarfile, time

root, out = sys.argv[1], sys.argv[2]
now = int(time.time())
meta = [m for m in (".PKGINFO", ".INSTALL") if os.path.exists(os.path.join(root, m))]
files = sorted(os.path.relpath(os.path.join(d, n), root)
               for d, dirs, names in os.walk(root) for n in dirs + names
               if os.path.relpath(os.path.join(d, n), root) not in meta)


def mtree_line(p):
    full = os.path.join(root, p)
    st = os.lstat(full)
    mode = format(st.st_mode & 0o7777, "o")
    if os.path.isdir(full):
        return f"./{p} time={now}.0 mode={mode} type=dir"
    with open(full, "rb") as f:
        data = f.read()
    return (f"./{p} time={now}.0 mode={mode} size={len(data)} "
            f"md5digest={hashlib.md5(data).hexdigest()} sha256digest={hashlib.sha256(data).hexdigest()}")


mtree = "#mtree\n/set type=file uid=0 gid=0 mode=644\n" + "".join(mtree_line(p) + "\n" for p in meta + files)
with open(os.path.join(root, ".MTREE"), "wb") as f:
    f.write(gzip.compress(mtree.encode(), mtime=now))


def as_root(ti):
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = now
    return ti


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    for p in [".MTREE"] + meta + files:
        t.add(os.path.join(root, p), arcname=p, recursive=False, filter=as_root)
subprocess.run(["zstd", "-19", "-q", "-f", "-o", out], input=buf.getvalue(), check=True)
