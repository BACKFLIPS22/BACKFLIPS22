#!/usr/bin/env python3
"""Builds the single-file install-pvedash.sh and README.md from src/.

    python3 build.py                  rebuild, using the repo named in the REPO file
    python3 build.py yourname/pvedash set the GitHub repo, then rebuild
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def read(*parts):
    with open(os.path.join(ROOT, *parts)) as f:
        return f.read().rstrip("\n")


def write(name, text, mode=0o644):
    path = os.path.join(ROOT, name)
    with open(path, "w") as f:
        f.write(text + "\n")
    os.chmod(path, mode)
    print(f"{name}: {len(text) // 1024} KB")


if len(sys.argv) > 1:
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", sys.argv[1]):
        sys.exit("The repo must look like username/repo")
    write("REPO", sys.argv[1])

repo, version = read("REPO"), read("VERSION")

out = read("src", "installer.sh")
for marker, name in (("@@CLI@@", "cli.sh"), ("@@COLLECTOR@@", "collector.py"), ("@@SERVER@@", "server.py"), ("@@PAGE@@", "index.html")):
    body = read("src", name)
    assert "PVEDASH_FILE_END" not in body, name
    assert out.count(marker) == 1, marker
    out = out.replace(marker, body)


def fill(text):
    text = text.replace("@@REPO@@", repo).replace("@@VERSION@@", version)
    assert "@@" not in text, re.findall(r"@@\w*@@?", text)
    return text


write("install-pvedash.sh", fill(out), 0o755)
write("README.md", fill(read("src", "README.md")))
if repo.startswith("YOUR-USERNAME/"):
    print("NOTE: the repo is still a placeholder. Set it with: python3 build.py yourname/pvedash")
