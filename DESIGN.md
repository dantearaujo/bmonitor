---
name: bmonitor
description: Monitor e controle remoto do Blackmagic Camera no Mac, no padrão dos players da Apple.
colors:
  rec-red: "#FF453A"
  alert-orange: "#FF9F0A"
  meter-green: "#30D158"
  meter-yellow: "#FFD60A"
  system-accent: "#0A84FF"
  video-black: "#000000"
  label-white: "#FFFFFF"
typography:
  timecode:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "20pt"
    fontWeight: 600
    fontFeature: "tnum"
  status:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "17pt"
    fontWeight: 600
    fontFeature: "tnum"
  rec-label:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "17pt"
    fontWeight: 700
  panel-value:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "28pt"
    fontWeight: 600
    fontFeature: "tnum"
  value:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "15pt"
    fontWeight: 600
    fontFeature: "tnum"
  value-compact:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 600
    fontFeature: "tnum"
  choice:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 600
    fontFeature: "tnum"
  label:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 500
  meter-scale:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "9pt"
    fontWeight: 500
    fontFeature: "tnum"
rounded:
  capsule: "9999px"
  card: "18pt"
  choice: "7pt"
  keycap: "5pt"
  mark: "3pt"
spacing:
  hud-edge: "16pt"
  titlebar-inset: "28pt"
  chip-x: "14pt"
  chip-x-tight: "10pt"
  chip-y: "8pt"
  bar: "6pt"
  bar-compact: "5pt"
  item-x: "14pt"
  item-x-compact: "12pt"
  item-x-tight: "8pt"
  item-y: "5pt"
  choice-gap: "6pt"
  popover: "18pt"
  card: "22pt"
  card-margin: "32pt"
components:
  hud-chip:
    textColor: "{colors.label-white}"
    rounded: "{rounded.capsule}"
    padding: "8pt 14pt"
  hud-card:
    textColor: "{colors.label-white}"
    rounded: "{rounded.card}"
    padding: "22pt"
  control-bar:
    rounded: "{rounded.capsule}"
    padding: "6pt"
  value-item:
    textColor: "{colors.label-white}"
    typography: "{typography.value}"
    padding: "5pt 14pt"
  value-item-failed:
    textColor: "{colors.rec-red}"
    typography: "{typography.value}"
  record-button:
    backgroundColor: "{colors.rec-red}"
    rounded: "{rounded.capsule}"
    size: "44pt"
  choice:
    textColor: "{colors.label-white}"
    typography: "{typography.choice}"
    rounded: "{rounded.choice}"
    padding: "0 8pt"
    height: "28pt"
  choice-on:
    backgroundColor: "{colors.system-accent}"
    textColor: "{colors.label-white}"
    rounded: "{rounded.choice}"
  choice-silence-on:
    backgroundColor: "{colors.rec-red}"
    textColor: "{colors.label-white}"
    rounded: "{rounded.choice}"
  popover:
    padding: "18pt"
    width: "340pt"
  keycap:
    textColor: "{colors.label-white}"
    rounded: "{rounded.keycap}"
    padding: "0 7pt"
    height: "22pt"
---

# Design System: bmonitor

## Overview

**Creative North Star: "O player da Apple sobre o set"**

O vídeo ocupa a janela inteira sobre preto puro (com o roteiro aberto, a janela inteira menos a coluna dele, no mesmo preto), e tudo o que não é imagem flutua por cima em Liquid Glass do macOS 26, no acabamento do QuickTime Player e do Final Cut Pro. O app não tem cor própria nem marca: o sistema dá o tipo (SF Pro), o vidro, os ícones (SF Symbols) e a cor de destaque. O app só reserva o vermelho do sistema para gravação e erro e o laranja para alerta. O tema é sempre escuro (`preferredColorScheme(.dark)`), então os valores de cor registrados são as variantes escuras do sistema.

O mesmo layout serve a dois papéis: leitura a 3 m e operação a 50 cm. Status de longe mora em duas cápsulas nos cantos de cima, sempre visíveis, com texto entre 17 e 20 pt. Controle de perto mora numa barra de vidro centralizada na base, que aparece com o mouse e some 3 s depois que ele para. Cada valor da barra abre um popover nativo do macOS; a câmera confirma e o valor muda.

O visual de palhetas (split-flap) foi testado e recusado em 20/10: cansava a leitura, não deixava claro onde ajustar e cobria o vídeo. Painéis fixos e blocos opacos sobre a imagem ficam fora deste mundo.

**Key Characteristics:**
- Vídeo de borda a borda sobre preto; nenhum painel fixo sobre ele. O roteiro, quando aberto, fica ao lado do vídeo e não por cima.
- Controles em cápsulas de vidro concêntricas, cantos contínuos.
- SF Pro com dígitos monoespaçados em todo número que muda.
- Cor só como sinal: vermelho grava ou falha, laranja alerta, destaque do sistema marca a escolha.
- Alerta muda de forma além de cor (ícone vira triângulo, microfone cortado, antena cortada).
- A interface some quando o mouse para; o status dos cantos fica.

## Colors

Paleta de sistema em modo escuro: neutros do macOS sobre preto, e cor apenas onde há estado a comunicar.

### Primary
- **Vermelho de REC** (systemRed, `Theme.rec`): ponto e palavra REC, borda de tally de 3 pt em volta do quadro durante a gravação, botão de gravar, valor que a câmera recusou, minutos restantes abaixo de 3 min, sinal caído, "Sem câmera", "Sem áudio" e "Sem som", zona de saturação do medidor e preenchimento da opção "Sem áudio" quando escolhida.

### Secondary
- **Laranja de alerta** (systemOrange, `Theme.warn`): minutos restantes entre 3 e 10 min e conexão com perdas. Nada mais.
- **Destaque do sistema** (accentColor; azul padrão no tema escuro): preenchimento da opção escolhida nos popovers. Segue a cor que o usuário escolheu no macOS; o valor no frontmatter é o padrão.

### Tertiary
- **Verde e amarelo do medidor** (systemGreen, systemYellow): só nas zonas do medidor de áudio, na convenção do app da Blackmagic. O amarelo também desenha a mira de foco, a convenção de câmera para o ponto focado.

### Neutral
- **Preto do vídeo**: fundo da janela e de toda área sem imagem. Em véu, escurece o quadro congelado (60%) e o fundo da tela de atalhos (40%).
- **Branco de rótulo**: texto primário sobre o vidro, em escadas de opacidade para estado. Na barra, item sob o mouse 12%, ligado ou aberto 20%, pressionado 28%. Nos popovers, opção em repouso 8%, sob o mouse 14%, pressionada 20%. Tecla desenhada: placa 12% com contorno 18%.
- **Secundário do sistema** (`.secondary`): rótulos dos valores, STBY, títulos de seção, notas e escala do medidor.

### Named Rules
**The Two Alarms Rule.** Vermelho é gravação, erro ou saturação; laranja é alerta. Nenhum dos dois decora, destaca seleção ou marca botão comum. O ponto de REC em espera é cinza secundário, não vermelho apagado.

**The Shape Plus Color Rule.** Todo estado que ganha cor também muda forma ou texto: o disco vira triângulo de alerta, o microfone ganha o corte, a antena ganha o corte, o valor vira "—". Cor nunca é o único sinal.

## Typography

**Display Font:** SF Pro (fonte do sistema)
**Body Font:** SF Pro (fonte do sistema)
**Label/Mono Font:** SF Pro com dígitos monoespaçados (`monospacedDigit()`), não uma fonte mono

**Character:** Uma família só, a do sistema, como nos apps da Apple. O peso semibold carrega os valores; a hierarquia vem de tamanho e de primário contra secundário, não de troca de família.

### Hierarchy
- **Panel value** (600, 28 pt, dígitos fixos): o valor grande no topo do popover de WB e de tint.
- **Timecode** (600, 20 pt, dígitos fixos): timecode na cápsula de REC, legível a 3 m.
- **Status** (600, 17 pt, dígitos fixos): minutos restantes e sinal na cápsula de saúde. REC e STBY usam 17 pt em 700.
- **Value** (600, 15 pt, dígitos fixos; 13 pt na janela estreita): valores da barra de controles e nome do microfone na cápsula.
- **Choice** (600, 13 pt, dígitos fixos): opções dos popovers. Nomes de lente em 12 pt, preset de luz em 11 pt.
- **Label** (500, 10 pt; 9 pt na janela estreita; secundário): rótulo sobre cada valor da barra ("ISO", "Shutter", "WB").
- **Meter scale** (500, 9 pt, dígitos fixos, secundário): números de dBFS no medidor grande.
- Estilos de texto do sistema nos popovers e cartões: títulos de seção em subheadline semibold secundário, títulos de cartão em title3 semibold, notas em callout secundário.

### Named Rules
**The Fixed Digits Rule.** Todo número que muda enquanto se olha (timecode, ISO, shutter, WB, tint, minutos, fps, dBFS, opções de lista) usa dígitos monoespaçados, para a largura não pular.

**The Natural Size Rule.** Texto de status e de valor nunca encolhe nem trunca para caber (`fixedSize`); quem cede é o layout, por variantes do `ViewThatFits`.

## Layout

O vídeo é encaixado (aspect fit) na janela, e a janela segue a proporção do vídeo; ao girar 90°, ela fica em pé. A barra de título fica oculta e os cantos de cima descem 28 pt para não colidir com os botões da janela. O HUD tem respiro de 16 pt em todas as bordas.

- **Bateria do iPhone** no canto de status, entre os minutos e o sinal: ícone de nível, raio quando carrega e porcentagem; laranja com 20% ou menos e vermelho com 10%, os pontos em que o iOS avisa de bateria fraca, e o ícone vira triângulo no alerta.
- **Nome da câmera** ("Câmera A · iPhone 17 Pro Max", o nome dos ajustes do Blackmagic Camera e o modelo) no alto, ao centro, na faixa dos botões da janela; aparece e some com os controles e é o título da janela.
- **Canto superior esquerdo, sempre visível:** cápsula de gravação com ponto de 12 pt, REC ou STBY, timecode, divisor e o áudio (ícone do microfone, nome curto e medidor de 96 × 14 pt). O contrato pedia só REC e timecode nesse canto; o build juntou o áudio na mesma cápsula, porque é o outro dado que se confere de longe.
- **Canto superior direito, sempre visível:** cápsula de saúde com minutos restantes e sinal (fps).
- **Base, centralizada, só com o mouse:** barra com ISO, shutter, FPS, WB, tint, foco e formato à esquerda, gravar no meio, lente, áudio, mudo, grade e girar à direita, separados por divisores de 26 pt de altura.
- **Centro:** livre. Só cartões de estado sem vídeo (procurando, conectando, sem câmera, vídeo parado) e a tela de atalhos ocupam o centro.

Janela estreita, na ordem em que o layout cede: o respiro aperta (14 para 10 pt nas cápsulas), a saúde troca "fps" só pelo ícone, o áudio desce para uma segunda linha da cápsula de gravação (que vira cartão de cantos 18 pt) e, em último caso, o nome do microfone sai. A barra compacta letra e respiro, depois aperta ainda mais numa linha só (respiro de 8 pt nos itens; os botões de ícone mantêm 44 pt, para não desnivelar do gravar) e, se ainda não couber, quebra em duas cápsulas: exposição em cima; gravar, lente, áudio e janela embaixo, 8 pt entre elas. Na barra, o áudio mostra só o nome curto da entrada ("iPhone", "Sem fio", "Sem áudio"; outros nomes cortados em 12 caracteres), do tamanho dos outros valores; o nome inteiro fica na cápsula, na dica e no painel. A opção sem áudio vem no idioma do iPhone ("None", "Não") e é reconhecida por ser a primeira da lista de entradas.

Popovers têm 340 pt de largura, 18 pt de respiro e 14 a 16 pt entre blocos. Grades de opção usam 6 pt de vão. Cartões centrais têm 22 pt de respiro e ficam a 32 pt das bordas.

### Named Rules
**The Edges Rule.** Status mora nos cantos de cima e controle na base; o centro do quadro fica com o vídeo. Nada novo entra no centro sem pedido do usuário.

## Elevation & Depth

Sem sombras. A profundidade vem do material: tudo o que flutua sobre o vídeo usa Liquid Glass regular do macOS 26 (`glassEffect`), interativo quando o elemento responde a clique, e cai para `ultraThinMaterial` em versões anteriores do sistema. Popovers e diálogos são os nativos do macOS. Sobre o próprio vídeo, legibilidade vem de traço duplo, não de sombra: a grade é branca 55% de 0,75 pt sobre preto 30% de 2 pt, e a mira de foco é amarela de 1,5 pt sobre preto 40% de 3 pt.

### Named Rules
**The Glass Only Rule.** Uma superfície sobre o vídeo, ou sobre o texto do roteiro, é vidro do sistema ou não existe. Sem fundos opacos, sem sombras desenhadas à mão, sem bordas decorativas no vidro.

## Shapes

A forma dominante é a cápsula: as duas cápsulas de status, a barra de controles e o realce de cada item da barra, que é cápsula concêntrica à borda da barra. Cartões (estados sem vídeo, atalhos, cápsula de gravação empilhada) usam cantos contínuos de 18 pt. Opções dos popovers têm 7 pt contínuos, teclas desenhadas 5 pt e marcas pequenas (miniatura da grade, quadrado de parar gravação) 3 pt. Círculos ficam para o que é círculo: o ponto de REC, o botão de gravar e os anéis das lentes.

## Components

### Buttons
- **Item da barra:** sem fundo em repouso, a cápsula clareia com o estado (12% sob o mouse, 20% ligado ou com popover aberto, 28% pressionado); texto sempre primário, cursor de link. Todo item da barra tem 44 pt de altura, a do gravar, para realces e estados ficarem nivelados (`Theme.barItem`). Ícones em 15 pt medium num alvo de 44 × 44 pt em qualquer largura de janela; o alvo é quadrado, para a marca de ligado ser um círculo.
- **Gravar:** disco vermelho de 30 pt dentro de anel branco 90% de 2 pt e 36 pt, alvo de 44 pt; gravando, ganha um quadrado branco de 11 pt. O disco é renderizado em grupo próprio para a vibrancy do vidro não desbotar o vermelho. Falha deixa o disco a 50%; pendente mostra indicador de progresso branco.
- **Ação dentro de popover** ("Medir o branco agora", "Focar agora", "Zerar"): botão `.bordered` do sistema, separado das grades de escolha.

### Chips
- **Opção de popover:** cantos de 7 pt, altura mínima 28 pt, respiro lateral 8 pt (3 pt nas lentes), branco 8% em repouso. Escolhida, preenche com a cor de destaque e o texto fica branco. A única exceção de cor é "Sem áudio", que preenche em vermelho quando escolhida, porque aí é alarme; fica separada no fim da lista por um divisor e pede confirmação se a câmera está gravando.
- **Cópia no Mac:** o botão que liga fica colado no gravar, na barra, um círculo par do gravar: alvo de 44 pt, círculo de 36 pt (o diâmetro do anel do gravar) e `laptopcomputer.and.arrow.down` em 14 pt semibold. O ícone não muda com o estado, então o estado é o círculo: desligado, anel branco a 35% de 2 pt e ícone a 75%; ligado, círculo branco a 92% e ícone preto, em grupo próprio contra a vibrancy; clique direito escolhe a pasta e abre o Finder. O menu Câmera repete as três ações. Gravando, o estado aparece na cápsula da direita, antes do tempo restante, `laptopcomputer.and.arrow.down` com "Mac" só enquanto a câmera grava e a cópia está ligada; em janela estreita fica só o ícone. Se a última cópia falhou, vira triângulo vermelho até um take salvar, com o erro na dica. O texto da dica diz que é o stream (resolução da câmera, 8 Mb/s), não o original.
- **Marca de sem cintilação:** lâmpada do SF Symbols (`lightbulb.fill`, 9 pt, secundária) ao lado do valor de shutter, a mesma na legenda do próprio popover.

### Cards / Containers
- **Cápsula de status:** vidro em cápsula, respiro 8 × 14 pt (10 pt na janela estreita).
- **Cartão central:** vidro com cantos de 18 pt, respiro 22 pt, título em title3 semibold com indicador de progresso e detalhe em callout secundário. "Sem câmera" leva o ícone do Blackmagic Camera (44 pt) à esquerda, porque a saída é abrir esse app.
- **Popover:** nativo, seta para cima, 340 pt; nota de falha em vermelho com triângulo no fim.

### Guia da busca
Enquanto procura o iPhone, a janela mostra um iPhone desenhado na tela inicial: os outros apps são quadrados apagados (branco 7%) e só o ícone real do Blackmagic Camera tem cor, 1,6 vez maior que os vizinhos, com uma seta azul (cor de destaque) na casa de cima. Ícone e seta pulsam juntos, 0,9 s ease-in-out em vai e volta (escala 1 a 1,08 e brilho azul); com Reduzir Movimento, ficam parados. Embaixo (ou ao lado, em janela deitada): título "Abra o Blackmagic Camera no iPhone" em 24 pt bold, a frase "não a Câmera do iPhone", uma cápsula de vidro com o diagnóstico do Mac (procurando, Rede Local bloqueada com atalho para os Ajustes, ou Mac sem rede, os dois com ícone laranja), os três ajustes numerados e o link do QR code da App Store, que abre num popover. O primeiro arranjo que couber ganha: o iPhone encolhe e os detalhes saem antes do ícone. Na primeira vez aparece logo; depois, só se a busca passar de 3 s, para não piscar a cada abertura. Com mais de um iPhone na rede, a busca mostra a escolha.

### Inputs / Fields
- Sliders, segmentados e switches são os nativos do macOS. O slider de câmera segue o valor confirmado quando parado e envia enquanto é arrastado; o passo vale no envio, sem marcas no trilho.

### Value Item
Rótulo de 10 pt secundário em cima, valor de 15 pt semibold embaixo, 1 pt entre os dois e respiro lateral de 14 pt (12 na barra compacta, 8 na apertada): o realce é uma cápsula de 44 pt de altura, e com menos respiro as pontas arredondadas encostam no texto. Pendente mostra um indicador mini ao lado até a câmera confirmar (prazo de 3 s); falha deixa o valor vermelho. Rótulo pode carregar contexto curto com ponto médio ("ISO · auto", "Lente · 13 mm").

### Painel de formato
Último item da exposição, depois de Foco e separado dele ("Formato · 4K · HEVC"); tecla `K`. Os quadros por segundo têm item próprio logo depois do Shutter ("FPS · 30", tecla `P`), porque é com o shutter que o fps se confere, e um painel só com a grade de fps da resolução atual (decisão do Dante em 22/10: dentro de "4K 30p" o fps passava despercebido). O painel de formato mostra só o que o iPhone publica, em grades de botões: resolução em 4 colunas, codec e espaço de cor em 2. Codec aparece por família (HEVC e H.264 antes dos ProRes) e a qualidade numa linha própria, que some quando a família só tem uma. O espaço de cor usa os nomes da tela do Blackmagic Camera (Rec.709, P3 D65, Rec.2020 · HDR, Apple Log · HDR), não os da API. Gravando, o painel inteiro (e o de fps) fica a 40% de opacidade, desativado, com um cadeado e a frase que explica a trava.

### Roteiro
Coluna dentro da janela do monitor, ao lado do vídeo e no mesmo preto, separada dele por um fio de 1 pt branco a 10%. Decisão do Dante em 22/10: a janela separada parecia um segundo app. Abre e fecha pelo botão de nota na barra do vídeo (`note.text`, aceso com o roteiro à vista, junto ou destacado), por ⌘2 e pelo menu Roteiro. A janela cresce para o lado do roteiro e o vídeo não muda de tamanho nem de lugar. Ao lado, o roteiro tem metade do lado maior do vídeo; acima ou abaixo (só com o vídeo deitado, onde o lado deixaria a janela 1,5 vez mais larga), 40% da largura dele, umas 8 linhas num vídeo de 960 pt. A janela mantém uma proporção fixa e o redimensionamento continua travado nela. Enquanto a janela cresce, o vídeo guarda o tamanho natural e o roteiro ganha o resto, como uma gaveta; se faltar espaço, o vídeo cede até o roteiro ter 320 pt ao lado ou 220 pt acima ou abaixo. O lugar é escolha do usuário, no menu Roteiro, no clique direito do botão e no menu "…", e cada orientação guarda a sua: em pé, esquerda ou direita (padrão direita); deitado, acima, abaixo, esquerda ou direita (padrão acima, porque com o iPhone em cima do monitor o olho fica perto da lente). Girar o vídeo leva o roteiro para o lugar da nova orientação. Abrir, fechar ou trocar de lugar deixa o vídeo no mesmo ponto da tela; a janela cresce ou encolhe em volta dele. Com o roteiro acima, os cantos de status sobem para a borda do vídeo e o nome da câmera sai, porque a faixa dos botões da janela fica sobre o roteiro. O lugar tem ícone próprio (`sidebar.left`, `sidebar.right`, `rectangle.topthird.inset.filled`, `rectangle.bottomthird.inset.filled`), usado no botão de juntar.

O roteiro também pode virar uma janela própria, que o usuário move e redimensiona à vontade. O botão de alternar fica na cápsula do roteiro e no menu "…" e no menu Roteiro. Junto da câmera, ele mostra `macwindow` (vira janela); destacado, mostra a barra lateral do lugar em que vai encaixar (vira barra lateral). Ao destacar, a janela nasce no lugar e no tamanho exatos em que o roteiro estava, e a janela da câmera encolhe em volta do vídeo; ao juntar, a janela da câmera cresce para o lugar escolhido daquela orientação. Destacada, a janela tem os três botões, fundo preto, nenhum fio de divisa, e lembra posição e tamanho; o mouse sobre ela também mostra a cápsula. Girar o vídeo não mexe nela. O botão vermelho só esconde o roteiro (⌘2 traz de volta, ainda destacado), e o app reabre como estava: junto ou destacado, à vista ou não.

Texto em SF Pro medium de 28 pt, a distância de computador (18 a 96 em passos de 2 com ⌘+ e ⌘−). Títulos ficam maiores em bold, listas levam marcador secundário e citação leva fio secundário. A frase atual fica a um terço da altura, e clicar num parágrafo leva o marcador até ele (cursor de link). O estado do texto segue a escada de opacidade do branco: frase atual 100%, por vir 60%, já dito 22%. A barra de 5 pt na cor de destaque ao lado da frase atual saiu em 22/10: borda colorida grossa em item de lista é um vício da categoria, e a forma além da cor agora é o lugar (a frase atual mora sempre no terço da altura) mais a contagem "Fala N de M" no canto. O texto esmaece em cima e embaixo: em cima, some antes do canto de status (livre até 40 pt e cheio a 110 pt, ou 10% e 25% da altura quando o roteiro é baixo); embaixo, com a cápsula à vista, o esmaecido termina 84 pt acima da base, para nenhuma letra passar por trás do vidro.

No canto de cima, à direita (fora dos botões da janela em qualquer lugar), fica "Fala 6 de 18" em 13 pt semibold secundário com dígitos fixos. Com Seguir a fala ligado, aparece antes o ícone `waveform`, na cor de destaque e animado enquanto o Mac ouve. Quando ele não está ouvindo, o motivo toma o lugar do número: "Preparando o reconhecimento…" em secundário, ou "Sem áudio da câmera" ou o erro do reconhecedor em laranja com triângulo, quebrando em até duas linhas.

A barra da câmera fica só sobre o vídeo (pedido do Dante, 22/10). Os controles do roteiro moram numa cápsula de vidro própria na base da coluna, na mesma altura e no mesmo vidro da barra, e aparecem e somem com ela: Seguir a fala (`waveform`, aceso a 20% e animado enquanto ouve), texto menor e maior (saem primeiro quando a coluna é estreita) e "…" com editar, colar, abrir arquivo, voltar ao início e o lado. ↑ e ↓ passam de frase pelo menu, só com o roteiro à vista e nenhum popover aberto, porque as setas são dos sliders. Sem roteiro, a coluna mostra Colar, Abrir arquivo e Escrever, sem a cápsula. Em edição, o Markdown cru fica em 17 pt, o canto de cima mostra "Editando o roteiro" e Concluído (⌘↩, esc também conclui), e os atalhos de uma tecla do app ficam desligados.

### Sobre e atualização
Duas janelas pequenas no mesmo desenho, no lugar das padrão do macOS e do Sparkle: fundo escuro sólido da janela (o vidro de janela inteira escondia os botões de fechar), barra de título oculta com os três botões, 620 a 640 pt de largura. Em cima, duas colunas separadas por um divisor: à esquerda o ícone do app (128 pt no Sobre, 112 na atualização), o nome em bold e a linha de apoio; à direita, uma lista. Embaixo, um cartão de cantos 14 pt em branco 6% com a ação. O botão principal é uma cápsula na cor de destaque com texto branco 13 pt semibold; o amarelo do Buy Me a Coffee fica fora, porque amarelo no app é medidor e mira de foco.

- **Sobre:** "por Dante Araujo" (link para o Instagram), versão com dígitos fixos e botão de copiar (vira um visto por 1,5 s). À direita, os links do site: site, código aberto, novidades e relatar um problema, cada um com ícone, título e detalhe. No cartão, "Gratuito e de código aberto", a frase do café do site, o botão "Me pague um café" e a linha de que o projeto é independente da Blackmagic Design.
- **Atualização:** abre sozinha quando há versão nova, 8 s depois de abrir o app; gravando, espera a gravação parar. À esquerda, "bmonitor 0.9.7", "Nova versão" na cor de destaque e a versão atual; à direita, "O que mudou" com as notas da versão em blocos (título em bold, itens com marcador), rolando. O cartão muda com o estado: oferta (Pular esta versão, Depois, Atualizar agora), barra de progresso do download em MB e da preparação, pronta para instalar (Depois, Instalar e reabrir) e instalando. Procurar pelo menu mostra uma versão compacta: procurando, em dia ou erro em laranja com triângulo.

### Ícone do app
O módulo de câmera traseira do iPhone 17 Pro, com três lentes, dentro das quatro marcas de canto de um visor. Decisão do Dante em 22/10, depois de quatro rodadas comparadas no Dock e no Finder. O app serve para quem grava com a câmera traseira e não se vê, então o ícone mostra a câmera, não o Mac. Fundo preto brilhante, cantos em branco, placa em vidro branco fosco com lentes pretas de aro metálico: o contraste mais forte das rodadas, para ler em 16 pt. O LED de REC fica aceso, com aro escuro, centro quase branco e o vermelho vazando na placa. Um fio de luz por dentro do contorno, mais forte em cima, desenha o ícone no Dock escuro, onde o preto sumiria.

Em 16 e 32 pt entra uma versão sem os cantos do visor, só a placa e as lentes, porque os cantos viravam ruído. As duas matrizes de 1024 px ficam em `scripts/icon/`, já no grid do macOS (corpo de 824 px, com sombra); a arte saiu de imagem gerada por IA, ampliada, com o LED repintado por código e os cantos do visor redesenhados com o mesmo raio e um recuo maior (8,5% do lado, contra 6,7% na arte), para respirarem da borda. O site usa a grande e, no favicon e no menu, a pequena.

### Audio Meter
O medidor do Blackmagic Camera: uma barra por canal sobre o trilho com as três zonas a 24% de opacidade, verde de -60 até -20 dBFS, amarelo até -9, vermelho até 0. A barra acesa toma a cor da zona e a marca de pico (1,5 pt; 2,5 pt no grande) segura 1 s e cai a 20 dB em 1,7 s, como o PPM tipo I. A escala comprime abaixo de -20 (metade da largura de -20 a 0). Redesenha a 30 Hz e apaga se o som parou há mais de 0,5 s. Pequeno na cápsula (96 × 14 pt, 2 pt entre canais); grande no popover de áudio (46 pt de altura, L e R, marcas e números de -40 a 0). Logo abaixo do grande fica o ganho da entrada: slider de 0 a 100% com o número ao lado, para ver o efeito no medidor enquanto arrasta, e ⌥↑ e ⌥↓ em passos de 5%. Cada entrada publica a faixa de ganho que aceita; o microfone do iPhone publica 1 a 1, e o slider fica desabilitado com uma nota que diz isso.

### Motion
A barra e a cápsula do roteiro aparecem e somem com fade de 0,25 s ease-out e deslizam 12 pt (a cápsula do roteiro só faz o fade com Reduzir Movimento, e a rolagem do roteiro salta em vez de deslizar); some 3 s depois do último movimento do mouse, nunca com popover aberto, e o cursor some junto. A mira de foco (56 pt, quatro cantos de 12 pt) fica 1 s e apaga em 0,4 s ease-out. A tela de atalhos entra e sai por opacidade.

### Tally e estados do quadro
Gravando, uma borda vermelha de 3 pt contorna o quadro. Sem câmera, a borda some, porque o estado é desconhecido. Quadro parado escurece com véu preto 60% até o vídeo voltar.

### Grade e área segura
As duas ficam sobre o quadro e podem ser somadas. A grade é traço branco 55% de 0,75 pt sobre preto 30% de 2 pt (terços, terços e centro, proporção áurea, cruz, ponto, linha dos olhos). A área segura de uma rede escurece com preto 35% o que a interface dela cobre e contorna o que fica visível no mesmo traço da grade; com o vídeo deitado, o que fica fora do recorte 9:16 do meio escurece com preto 55%. O quadrado central (1:1) não é medida de rede: é o recorte de um post quadrado, de borda a borda no lado menor do vídeo inteiro, e escurece o resto com preto 35%. As medidas moram em `SafeZone` (MonitorCore), com fonte e data, e um teste confere cada número. Escolha no popover da grade, em seções separadas, e `Z` liga e desliga.

### Keycap
Tecla desenhada da tela de atalhos: 12 pt semibold, placa branca 12% com contorno 0,5 pt a 18%, cantos de 5 pt, mínimo 26 × 22 pt, coluna fixa de 56 pt para os nomes alinharem entre seções.

## Do's and Don'ts

### Do:
- **Do** colocar toda superfície nova sobre o vídeo em `hudGlass`: cápsula para status e controles, cantos contínuos de 18 pt para cartões.
- **Do** usar `Theme.value` (SF Pro semibold com dígitos monoespaçados) para todo valor numérico que muda.
- **Do** mostrar o valor que a câmera confirmou, com indicador de pendente até 3 s e vermelho na falha.
- **Do** fazer o alerta mudar de ícone ou texto além da cor.
- **Do** deixar o layout ceder por variantes do `ViewThatFits` (respiro, depois compacto, depois empilhado), mantendo o texto em tamanho natural.
- **Do** marcar a escolha num popover com a cor de destaque do sistema.

### Don't:
- **Don't** usar vermelho ou laranja fora de gravação, erro, saturação do medidor e alerta.
- **Don't** pôr painel fixo, bloco opaco ou status novo no centro do quadro.
- **Don't** voltar às palhetas split-flap nem a qualquer cor ou fonte de marca própria.
- **Don't** desenhar sombras; profundidade é o vidro do sistema.
- **Don't** esconder a barra com um popover aberto, nem esconder as cápsulas dos cantos.
