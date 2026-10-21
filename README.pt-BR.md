<p align="center"><a href="README.md">🇺🇸 Read in English</a></p>

<p align="center"><img src="docs/icon.png" width="128" alt="ícone do bmonitor"></p>

<h1 align="center">bmonitor</h1>

<p align="center">Monitore e controle pelo Mac um iPhone rodando o <b>Blackmagic Camera</b>.<br>
Vídeo e áudio ao vivo pela Wi‑Fi, com cerca de 0,3 s de atraso.</p>

<p align="center"><img alt="Plataforma" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" />&nbsp;<img alt="Swift" src="https://img.shields.io/badge/swift-6.0-orange" />&nbsp;<img alt="Licença" src="https://img.shields.io/badge/license-MIT-green" />&nbsp;<img alt="Versão mais recente" src="https://img.shields.io/github/v/release/dantearaujo/bmonitor" /></p>

<p align="center">
  <a href="https://www.buymeacoffee.com/dantearaujo">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="42" alt="Buy Me a Coffee" />
  </a>
</p>

<h3 align="center"><a href="https://github.com/dantearaujo/bmonitor/releases/latest/download/bmonitor.dmg">⬇️ Baixar o bmonitor para Mac</a></h3>

<p align="center"><sub>Versão mais recente · macOS 14 Sonoma ou mais novo · Apple Silicon e Intel · <a href="#instalar">como instalar</a> · <a href="https://bmonitor.app/pt/">bmonitor.app</a></sub></p>

<p align="center"><b>⚠️ Beta público (0.9.5).</b> Funciona todo dia no setup do autor, mas até agora foi testado em dois Macs (macOS 26 e macOS 14) e um iPhone. Espere arestas e <a href="https://github.com/dantearaujo/bmonitor/issues">relate o que encontrar</a>.</p>

O app fala português do Brasil e inglês, seguindo o idioma do seu Mac.

---

## O que ele faz

Você se grava com um iPhone no tripé. O bmonitor transforma o Mac ao lado no monitor e no controle remoto da câmera, sem precisar de um segundo iPhone ou iPad.

- **Monitor:** vídeo ao vivo numa janela comum do Mac, deitada ou em pé, com aviso de gravação (borda vermelha), timecode, tempo de gravação restante e estado do sinal. Grades de enquadramento: terços, proporção áurea, cruz central e outras. Áreas seguras do vídeo vertical mostram o que o Instagram e o Facebook, o TikTok e o YouTube Shorts cobrem, além do recorte do grid do perfil (3:4) e de um quadrado central (1:1).
- **Áudio:** o nome do microfone ativo e um medidor de pico L/R no estilo do medidor da própria Blackmagic (verde, amarelo e vermelho), além do som da câmera no Mac, que começa mudo.
- **Cópia no Mac:** opcional, num botão ao lado do gravar. Cada take também é salvo no Mac a partir do stream, na resolução da câmera e a cerca de 8 Mb/s, com o nome do clipe do iPhone, na pasta Filmes (`~/Movies/bmonitor`). O original fica no iPhone.
- **Controle remoto:** iniciar e parar a gravação, ISO, shutter (velocidade ou ângulo), balanço de branco com presets de luz, tint, foco (clique no vídeo para focar ali), zoom, lente, estabilização, origem do áudio e ganho do áudio (com microfone externo; o microfone do iPhone não aceita ajuste de ganho).
- **Teclado:** uma tecla por controle (`I` ISO, `S` shutter, `W` balanço de branco, `T` tint, `L` lente, `A` áudio, `M` mudo, `G` grade, `Z` área segura, `F` focar agora), `⌥↑` `⌥↓` para o ganho do áudio, `⌘R` para gravar e `⌘→` para girar. `⌘/` mostra todos.
- **Primeira abertura:** enquanto procura o iPhone, o bmonitor mostra qual app abrir (o Blackmagic Camera, não a Câmera do iPhone), os ajustes que precisam estar ligados e se o Mac está bloqueando a Rede Local.
- **Atualiza sozinho:** o bmonitor procura versão nova uma vez por dia e pergunta antes de instalar. Também dá para usar **bmonitor › Procurar atualizações…**.
- **Legível a 3 m:** o status fica nos cantos de cima, em letra grande. A barra de controles aparece quando você mexe o mouse e some depois de 3 s.

## Requisitos

| | |
|---|---|
| Mac | macOS 14 Sonoma ou mais novo, Apple Silicon ou Intel (testado no macOS 26 Tahoe com Apple Silicon e no macOS 14 Sonoma; Macs Intel e o macOS 15 ainda não foram testados neste beta, conte como foi) |
| iPhone | [Blackmagic Camera](https://apps.apple.com/app/blackmagic-camera/id6449580241) (gratuito), testado na versão 3.5 |
| Rede | Mac e iPhone na **mesma rede Wi‑Fi** |

## Instalar

1. [Baixe o bmonitor.dmg](https://github.com/dantearaujo/bmonitor/releases/latest/download/bmonitor.dmg), sempre a versão mais recente. As versões anteriores ficam em [Releases](https://github.com/dantearaujo/bmonitor/releases).
2. Abra o `.dmg` e arraste o **bmonitor** para **Aplicativos**.
3. Abra o bmonitor. O macOS pede para confirmar a abertura de um app baixado da internet: clique em **Abrir**. O bmonitor é assinado e notarizado pela Apple.
4. Quando o macOS pedir para o bmonitor **encontrar dispositivos na rede local**, clique em **Permitir**. Sem isso, o app não enxerga o iPhone.

## Configurar o iPhone

Faça uma vez no app Blackmagic Camera:

1. Abra o Blackmagic Camera e entre nos ajustes dele.
2. Em **Remote Camera Control**, escolha **Remote Camera**. Se ele perguntar para que a câmera fica disponível, permita controle e monitoramento.
3. Em **Network Access**, ligue o **servidor HTTP**.
4. Libere o Blackmagic Camera na rede local: no iOS, **Ajustes › Privacidade e Segurança › Rede Local › Blackmagic Camera** ligado.

A cada gravação:

- conecte o iPhone e o Mac na mesma Wi‑Fi;
- deixe o Blackmagic Camera aberto **na tela de câmera**;
- desligue o bloqueio automático (no iOS, **Ajustes › Tela e Brilho › Bloqueio Automático › Nunca**), senão o stream para quando a tela bloqueia.

Depois, abra o bmonitor. Ele acha o iPhone sozinho e mostra o vídeo em poucos segundos. Com mais de um iPhone na rede, ele pergunta qual usar.

## O que o bmonitor muda no seu iPhone

O bmonitor recebe o vídeo pelo recurso de **live** do Blackmagic Camera, o mesmo usado para transmitir para o YouTube e outras plataformas:

- Na primeira conexão, ele cria no Blackmagic Camera uma plataforma de transmissão chamada **Mac Monitor SRT**. Ele só envia de novo se o endereço do seu Mac mudar.
- Enquanto o bmonitor está aberto, essa é a plataforma ativa e o iPhone transmite para o seu Mac.
- Quando você fecha o bmonitor (`⌘Q`, fechando a janela ou com Ctrl‑C no terminal), ele para a transmissão e **devolve a plataforma que você usava antes**.
- Se o bmonitor for fechado à força ou travar, o iPhone continua apontando para o Mac. Abra o bmonitor e feche normalmente uma vez, e a sua plataforma original volta.

A gravação continua no iPhone, na qualidade escolhida lá. A transmissão para o Mac não muda os ajustes de gravação.

## Se algo não funcionar

| Sintoma | O que conferir |
|---|---|
| "Procurando o iPhone" não termina | Mesma Wi‑Fi nos dois; Blackmagic Camera aberto na tela de câmera; Remote Camera Control em Remote Camera; servidor HTTP ligado; rede local liberada para **os dois** apps (no Mac: Ajustes do Sistema › Privacidade e Segurança › Rede Local). VPNs e redes de convidados costumam impedir que os aparelhos se vejam. |
| Conecta, mas fica em "Aguardando vídeo" | Um firewall no Mac pode estar bloqueando a transmissão que chega (porta UDP 9000). Libere o bmonitor em Ajustes do Sistema › Rede › Firewall. |
| "Sem câmera" | Blackmagic Camera fechado ou iPhone bloqueado. Abra de novo; o bmonitor reconecta sozinho. |
| O vídeo engasga | Wi‑Fi fraca. Chegue mais perto do roteador ou use a rede de 5 GHz. O aviso "Perdas", no canto de cima à direita, mostra pacotes perdidos. |

## Privacidade

O bmonitor não coleta nada. Ele conversa só com o iPhone na sua rede local: sem conta, sem estatística de uso e sem acesso à internet.

## Compilar a partir do código

```sh
brew install srt cmake
swift build -c release
swift test
scripts/build-app.sh --install --dmg   # bmonitor.app em /Applications e um .dmg em .build/dist
```

Para desenvolver, o pacote Swift usa a libsrt do Homebrew. Já o script de empacotamento compila a libsrt e o OpenSSL a partir do código-fonte, universais e para macOS 14 em diante (`scripts/build-deps.sh`), põe as duas dentro do app, gera o ícone (`scripts/make-icon.swift`) e assina ad hoc. O `DESIGN.md` documenta a interface. Os comentários do código estão em português.

## Como funciona

O Mac conversa com a API REST e WebSocket do Blackmagic Camera (porta 4444) para ler o estado e mandar os controles. Para vídeo e áudio, ele aponta a transmissão da câmera (SRT, MPEG‑TS com HEVC e AAC) para si mesmo, separa e decodifica cada quadro com o VideoToolbox, sem fila de espera. Do vidro da câmera ao vidro da tela, isso mede cerca de 0,3 s, a maior parte do lado do iPhone.

## Apoie

O bmonitor é grátis e tem licença MIT. Se ele te poupou uma ida até o tripé, você pode [me pagar um café](https://www.buymeacoffee.com/dantearaujo).

## Licença

MIT, veja [LICENSE](LICENSE). Bibliotecas incluídas e marcas: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

O bmonitor é um projeto independente, sem ligação nem endosso da Blackmagic Design.
