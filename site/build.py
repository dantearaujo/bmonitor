#!/usr/bin/env python3
"""Gera site/dist a partir dos modelos em src/ e de um JSON de textos por página e idioma.

Uso: python3 site/build.py
Cada página tem um modelo (src/index.html, src/guide.html, src/steamos.html) e os textos em i18n/ (a página
inicial em i18n/<idioma>.json, as outras em i18n/<página>/<idioma>.json, por cima dos textos
da inicial). O caminho de cada página sai da chave "path". {{>nome}} inclui src/partials/nome.html.
Chave que falta num idioma ou placeholder sem valor derruba o build, para as versões não divergirem.
"""

import hashlib
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

# Valores que dependem do idioma, não do texto.
EXTRA = {
    "en": {"alt_lang": "pt-BR", "readme_url": f"{REPO}#set-up-the-iphone"},
    "pt": {"alt_lang": "en", "readme_url": f"{REPO}/blob/main/README.pt-BR.md#configurar-o-iphone"},
}
# Páginas além da inicial: nome do modelo em src/ e da pasta de textos em i18n/.
PAGES = ["index", "guide", "steamos"]


SITE = "https://bmonitor.app"
AI_BOTS = ["GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User",
           "PerplexityBot", "Perplexity-User", "Google-Extended", "Applebot-Extended", "CCBot"]


def plain(text: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", text)).replace("\u00a0", " ")


def dump(data) -> str:
    return json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")


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
    return dump(data)


def guide_jsonld(s: dict) -> str:
    """TechArticle e trilha do guia comparativo."""
    url = SITE + s["path"]
    data = [
        {
            "@context": "https://schema.org",
            "@type": "TechArticle",
            "headline": plain(s["g_h1"]),
            "description": plain(s["description"]),
            "url": url,
            "inLanguage": s["lang"],
            "datePublished": s["g_date_iso"],
            "dateModified": s["g_date_iso"],
            "author": {"@type": "Person", "name": "Dante Araujo", "url": "https://instagram.com/dantearaujo"},
            "publisher": {"@type": "Organization", "name": "bmonitor", "url": SITE + "/"},
            "image": SITE + "/assets/og.png",
            "about": ["iPhone", "Blackmagic Camera", "camera monitor"],
        },
        {
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "bmonitor", "item": SITE + s["home"]},
                {"@type": "ListItem", "position": 2, "name": plain(s["g_crumb"]), "item": url},
            ],
        },
    ]
    return dump(data)


def steamos_jsonld(s: dict) -> str:
    """Página da versão para SteamOS e trilha."""
    url = SITE + s["path"]
    data = [
        {
            "@context": "https://schema.org",
            "@type": "WebPage",
            "name": plain(s["title"]),
            "description": plain(s["description"]),
            "url": url,
            "inLanguage": s["lang"],
            "about": {
                "@type": "SoftwareApplication",
                "name": "bmonitor for SteamOS",
                "applicationCategory": "MultimediaApplication",
                "operatingSystem": "SteamOS",
                "author": {"@type": "Person", "name": "Dante Araujo", "url": "https://instagram.com/dantearaujo"},
            },
        },
        {
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "bmonitor", "item": SITE + s["home"]},
                {"@type": "ListItem", "position": 2, "name": "SteamOS", "item": url},
            ],
        },
    ]
    return dump(data)


def include(template: str) -> str:
    return re.sub(r"\{\{>(\w+)\}\}", lambda m: (SRC / "partials" / f"{m.group(1)}.html").read_text().rstrip("\n"), template)


def render(template: str, strings: dict, name: str) -> str:
    def sub(m):
        key = m.group(1)
        if key not in strings:
            sys.exit(f"{name}: falta a chave {key!r}")
        return strings[key]

    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def main():
    langs = sorted(p.stem for p in (ROOT / "i18n").glob("*.json"))
    home = {l: json.loads((ROOT / "i18n" / f"{l}.json").read_text()) for l in langs}
    pages = {}
    for page in PAGES:
        texts = {}
        for l in langs:
            extra = {} if page == "index" else json.loads((ROOT / "i18n" / page / f"{l}.json").read_text())
            texts[l] = {**home[l], **extra}
        base = set(texts["en"])
        for l, s in texts.items():
            if set(s) != base:
                sys.exit(f"{page}/{l}.json diverge de en.json: {sorted(set(s) ^ base)}")
        pages[page] = texts

    # Esvazia em vez de apagar a pasta, para um servidor local aberto nela continuar servindo.
    DIST.mkdir(exist_ok=True)
    for child in DIST.iterdir():
        shutil.rmtree(child) if child.is_dir() else child.unlink()
    shutil.copytree(SRC / "assets", DIST / "assets")
    for f in ("style.css", "main.js"):
        shutil.copy2(SRC / f, DIST / f)
    (DIST / "CNAME").write_text("bmonitor.app\n")

    # Para LLMs e buscadores: os .txt da raiz de src (llms.txt escrito à mão e a chave do IndexNow)
    # vão como estão; llms-full.txt é o README inteiro.
    for f in SRC.glob("*.txt"):
        shutil.copy2(f, DIST / f.name)
    readme = (ROOT.parent / "README.md").read_text()
    (DIST / "llms-full.txt").write_text(f"# bmonitor: full documentation\n\nSource: {REPO} (README.md). Website: {SITE}/\n\n{readme}")
    bots = "".join(f"User-agent: {b}\nAllow: /\n\n" for b in AI_BOTS)
    (DIST / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\n{bots}Sitemap: {SITE}/sitemap.xml\n")

    urls = ""
    for page, texts in pages.items():
        alts = "".join(f'<xhtml:link rel="alternate" hreflang="{s["lang"]}" href="{SITE}{s["path"]}"/>' for s in texts.values())
        urls += "".join(f"<url><loc>{SITE}{s['path']}</loc>{alts}</url>" for s in texts.values())
    (DIST / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">'
                                      f"{urls}</urlset>\n")

    versions = {f: hashlib.sha1((SRC / f).read_bytes()).hexdigest()[:8] for f in ("style.css", "main.js")}
    for page, texts in pages.items():
        template = include((SRC / f"{page}.html").read_text())
        heads = [f'<link rel="alternate" hreflang="{s["lang"]}" href="{SITE}{s["path"]}">' for s in texts.values()]
        heads.append(f'<link rel="alternate" hreflang="x-default" href="{SITE}{texts["en"]["path"]}">')
        for l, s in texts.items():
            other = next(o for k, o in texts.items() if k != l)
            values = {**s, **EXTRA[l], "home": home[l]["path"], "guide_path": pages["guide"][l]["path"],
                      "steamos_path": pages["steamos"][l]["path"],
                      "alt_path": other["path"], "alternates": "\n".join(heads),
                      "guide_current": ' aria-current="page"' if page == "guide" else "",
                      "steamos_current": ' aria-current="page"' if page == "steamos" else ""}
            values["jsonld"] = {"index": jsonld, "guide": guide_jsonld, "steamos": steamos_jsonld}[page](values)
            out = DIST / s["path"].strip("/") / "index.html"
            out.parent.mkdir(parents=True, exist_ok=True)
            page_html = render(template, values, f"{page}/{l}")
            # Versão no endereço do CSS e do JS, para o cache do navegador não juntar HTML novo com CSS velho.
            for f, v in versions.items():
                page_html = page_html.replace(f'"/{f}"', f'"/{f}?v={v}"')
            out.write_text(page_html)
            print(f"{page}/{l}: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
