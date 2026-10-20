# bmonitor

App nativo de macOS (Swift, SwiftUI) que monitora e controla um iPhone rodando o Blackmagic Camera pela Wi‑Fi. Visão geral, instalação e o que o app muda no iPhone estão no `README.md`; o sistema visual está em `DESIGN.md`.

## Como rodar

- Requer `brew install srt cmake`. Para desenvolver, o módulo `CSRT` acha a libsrt do Homebrew pelo pkg-config. O app empacotado não usa a do Homebrew (ela exige a versão do macOS da máquina que compilou): `scripts/build-deps.sh` compila libsrt 1.5.7 e OpenSSL 4.0.3 universais, macOS 14+, com nomes @rpath, e `build-app.sh` compila o app universal contra elas e recusa qualquer binário que peça mais que o macOS 14.
- `swift build -c release && swift test`. Os testes de demux e áudio precisam de `Tests/MonitorCoreTests/Fixtures/stream.ts`, que não vai para o repo; sem ele, são pulados (ver `StreamFixture.swift`).
- App instalado: `scripts/build-app.sh --install --dmg` monta `bmonitor.app` (libsrt e OpenSSL dentro do pacote, ícone de `scripts/make-icon.swift`, assinatura ad hoc), copia para `/Applications` e gera o `.dmg`.
- Capturas de revisão: `bmonitor --open-panel <iso|shutter|whiteBalance|tint|focus|lens|audio|grid>` abre o popover ao conectar; `--show-shortcuts` abre a tela de atalhos; `--simulate-camera-gone`, `--simulate-lost`, `--simulate-loss`, `--simulate-recording` e `--simulate-remaining <segundos>` mostram esses estados com a câmera ligada; `--skip-bonjour` testa a volta ao último iPhone. Abra uma instância por vez e espere a anterior devolver a plataforma.
- `latency-probe --camera <ip-do-iphone>` mede o atraso do receptor sem interface.
- Idiomas: português é a base (as chaves são o texto em português do código) e `Localization/en.lproj/Localizable.strings` traduz para inglês; o app segue o idioma do sistema. Texto que vira `String` antes da tela usa `String(localized:)`; interpolação vira `%lld` (Int) ou `%@` (String) na chave. Só o `.app` empacotado carrega as traduções: o binário solto (`swift run`) fica em português. Para conferir: `bmonitor.app/Contents/MacOS/bmonitor -AppleLanguages "(en)" -NSShowNonLocalizedStrings YES` registra no log toda chave sem tradução.
- Release notarizada: `scripts/build-app.sh --notarize --dmg` assina com o Developer ID do `.env` (fora do git: `SIGNING_IDENTITY`, `NOTARY_PROFILE`), notariza o app e o `.dmg` e anexa o selo; confira com `spctl -a -vv -t install .build/dist/bmonitor.dmg` ("Notarized Developer ID"). Sem `.env`, o script assina ad hoc.
- Atualização automática (Sparkle): `scripts/build-app.sh --notarize --dmg --appcast` também gera `.build/dist/appcast.xml`, assinado com a chave EdDSA do Keychain (conta `bmonitor`; cópia no 1Password). Suba o `appcast.xml` em toda release: o app lê `releases/latest/download/appcast.xml`. `--check-updates-now` testa a busca ao abrir. O número de build (`CFBundleVersion`) é a contagem de commits e precisa crescer a cada release.
- Release: suba os dois `.dmg` (`bmonitor-<versão>.dmg` e `bmonitor.dmg`) e o `appcast.xml` e marque a release como "latest", não como pré-release. O botão de download do README aponta para `releases/latest/download/bmonitor.dmg`, que ignora pré-releases.

## O que o código precisa respeitar

- O caminho de vídeo é **sem fila**: cada quadro sai do demux assim que o pacote TS com enchimento fecha o PES, decodifica de forma síncrona e vai para a camada com `DisplayImmediately`. Qualquer buffer novo no caminho soma atraso visível; meça vidro a vidro antes e depois.
- O som segue a mesma regra, com uma exceção: o `AudioMonitor` agenda uma folga de dois quadros AAC (~43 ms) ao começar e descarta acima de 6 na fila (~128 ms). Mudo não toca a saída do Mac.
- O app muda a plataforma de livestream ativa do iPhone. Toda saída do app devolve a plataforma original e para o stream (SIGINT, SIGTERM e fechar a janela já fazem isso; `kill -9` não). A original fica em disco (`originalLivestreamPlatform`).
- Reenviar a plataforma customizada com o mesmo nome faz o Blackmagic Camera mostrar "Platforms Import Failed": envie só quando faltar ou quando o endereço mudar.
- Se o stream começa sem o Mac escutando, o iPhone fica em `Interrupted` e não tenta de novo: mande `stop` e `start`.
- O iPhone impõe 60 ms de buffer SRT e descarta parâmetros na URL da plataforma.
- Formatos de PUT que divergem da documentação da Blackmagic: foco e zoom só com `normalised`; shutter em ângulo exige antes `PUT /video/shutter/measurement`; `/lens/focus/autoFocus` com `mode: OneShot` fechou o Blackmagic Camera e não é oferecido.
