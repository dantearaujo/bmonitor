#!/usr/bin/env python3
"""Gera site/dist a partir de src/index.html e de um JSON de textos por idioma.

Uso: python3 site/build.py
Inglês sai em dist/index.html e português em dist/pt/index.html. Chave que falta
num idioma ou placeholder sem valor derruba o build, para as versões não divergirem.
"""

import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
DIST = ROOT / "dist"
REPO = "https://github.com/dantearaujo/bmonitor"

# Valores que dependem do par de idiomas, não do texto.
EXTRA = {
    "en": {"alt_path": "/pt/", "alt_lang": "pt-BR", "readme_url": f"{REPO}#set-up-the-iphone"},
    "pt": {"alt_path": "/", "alt_lang": "en", "readme_url": f"{REPO}/blob/main/README.pt-BR.md#configurar-o-iphone"},
}


def render(template: str, strings: dict, name: str) -> str:
    def sub(m):
        key = m.group(1)
        if key not in strings:
            sys.exit(f"{name}: falta a chave {key!r}")
        return strings[key]

    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def main():
    template = (SRC / "index.html").read_text()
    langs = {p.stem: json.loads(p.read_text()) for p in sorted((ROOT / "i18n").glob("*.json"))}

    keys = {name: set(s) for name, s in langs.items()}
    base = keys["en"]
    for name, k in keys.items():
        if k != base:
            sys.exit(f"{name}.json diverge de en.json: {sorted(k ^ base)}")

    # Esvazia em vez de apagar a pasta, para um servidor local aberto nela continuar servindo.
    DIST.mkdir(exist_ok=True)
    for child in DIST.iterdir():
        shutil.rmtree(child) if child.is_dir() else child.unlink()
    shutil.copytree(SRC / "assets", DIST / "assets")
    for f in ("style.css", "main.js"):
        shutil.copy2(SRC / f, DIST / f)
    (DIST / "CNAME").write_text("bmonitor.app\n")

    for name, strings in langs.items():
        html = render(template, {**strings, **EXTRA[name]}, name)
        out = DIST / strings["path"].strip("/") / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(html)
        print(f"{name}: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
