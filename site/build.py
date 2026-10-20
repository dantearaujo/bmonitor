#!/usr/bin/env python3
"""Gera site/dist a partir de src/index.html e de um JSON de textos por idioma.

Uso: python3 site/build.py
Inglês sai em dist/index.html e português em dist/pt/index.html. Chave que falta
num idioma ou placeholder sem valor derruba o build, para as versões não divergirem.
"""

import html
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


SITE = "https://bmonitor.app"
AI_BOTS = ["GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User",
           "PerplexityBot", "Perplexity-User", "Google-Extended", "Applebot-Extended", "CCBot"]


def plain(text: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", text)).replace("\u00a0", " ")


def jsonld(s: dict) -> str:
    """SoftwareApplication e FAQPage do idioma, a partir dos mesmos textos da página."""
    faq = [{"@type": "Question", "name": plain(s[f"q{i}"]),
            "acceptedAnswer": {"@type": "Answer", "text": plain(s[f"a{i}"])}}
           for i in range(1, 100) if f"q{i}" in s]
    data = [
        {
            "@context": "https://schema.org",
            "@type": "SoftwareApplication",
            "name": "bmonitor",
            "url": SITE + s["path"],
            "description": plain(s["description"]),
            "applicationCategory": "MultimediaApplication",
            "operatingSystem": "macOS 14 or later",
            "inLanguage": ["en", "pt-BR"],
            "isAccessibleForFree": True,
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
            "downloadUrl": f"{REPO}/releases/latest/download/bmonitor.dmg",
            "image": SITE + "/assets/og.png",
            "license": "https://opensource.org/licenses/MIT",
            "author": {"@type": "Person", "name": "Dante Araujo", "url": "https://instagram.com/dantearaujo"},
            "sameAs": [REPO],
        },
        {"@context": "https://schema.org", "@type": "FAQPage", "inLanguage": s["lang"], "mainEntity": faq},
    ]
    return json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")


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

    # Para LLMs e buscadores: llms.txt escrito à mão, llms-full.txt é o README inteiro.
    shutil.copy2(SRC / "llms.txt", DIST / "llms.txt")
    readme = (ROOT.parent / "README.md").read_text()
    (DIST / "llms-full.txt").write_text(f"# bmonitor: full documentation\n\nSource: {REPO} (README.md). Website: {SITE}/\n\n{readme}")
    bots = "".join(f"User-agent: {b}\nAllow: /\n\n" for b in AI_BOTS)
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\n{bots}Sitemap: {SITE}/sitemap.xml\n")
    alts = "".join(f'<xhtml:link rel="alternate" hreflang="{l["lang"]}" href="{SITE}{l["path"]}"/>' for l in langs.values())
    urls = "".join(f"<url><loc>{SITE}{l['path']}</loc>{alts}</url>" for l in langs.values())
    (DIST / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">'
                                      f"{urls}</urlset>\n")

    for name, strings in langs.items():
        page = render(template, {**strings, **EXTRA[name], "jsonld": jsonld(strings)}, name)
        out = DIST / strings["path"].strip("/") / "index.html"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(page)
        print(f"{name}: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
