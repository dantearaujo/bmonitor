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
  item-x: "10pt"
  item-x-compact: "6pt"
  item-x-tight: "4pt"
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
    padding: "5pt 10pt"
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

O vídeo ocupa a janela inteira sobre preto puro, e tudo o que não é imagem flutua por cima em Liquid Glass do macOS 26, no acabamento do QuickTime Player e do Final Cut Pro. O app não tem cor própria nem marca: o sistema dá o tipo (SF Pro), o vidro, os ícones (SF Symbols) e a cor de destaque. O app só reserva o vermelho do sistema para gravação e erro e o laranja para alerta. O tema é sempre escuro (`preferredColorScheme(.dark)`), então os valores de cor registrados são as variantes escuras do sistema.

O mesmo layout serve a dois papéis: leitura a 3 m e operação a 50 cm. Status de longe mora em duas cápsulas nos cantos de cima, sempre visíveis, com texto entre 17 e 20 pt. Controle de perto mora numa barra de vidro centralizada na base, que aparece com o mouse e some 3 s depois que ele para. Cada valor da barra abre um popover nativo do macOS; a câmera confirma e o valor muda.

O visual de palhetas (split-flap) foi testado e recusado em 20/10: cansava a leitura, não deixava claro onde ajustar e cobria o vídeo. Painéis fixos e blocos opacos sobre a imagem ficam fora deste mundo.

**Key Characteristics:**
- Vídeo de borda a borda sobre preto; nenhum painel fixo.
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

- **Canto superior esquerdo, sempre visível:** cápsula de gravação com ponto de 12 pt, REC ou STBY, timecode, divisor e o áudio (ícone do microfone, nome curto e medidor de 96 × 14 pt). O contrato pedia só REC e timecode nesse canto; o build juntou o áudio na mesma cápsula, porque é o outro dado que se confere de longe.
- **Canto superior direito, sempre visível:** cápsula de saúde com minutos restantes e sinal (fps).
- **Base, centralizada, só com o mouse:** barra com ISO, shutter, WB, tint e foco à esquerda, gravar no meio, lente, áudio, mudo, grade e girar à direita, separados por divisores de 26 pt de altura.
- **Centro:** livre. Só cartões de estado sem vídeo (procurando, conectando, sem câmera, vídeo parado) e a tela de atalhos ocupam o centro.

Janela estreita, na ordem em que o layout cede: o respiro aperta (14 para 10 pt nas cápsulas), a saúde troca "fps" só pelo ícone, o áudio desce para uma segunda linha da cápsula de gravação (que vira cartão de cantos 18 pt) e, em último caso, o nome do microfone sai. A barra compacta letra e respiro, depois aperta ainda mais numa linha só (respiro de 4 pt nos itens e botões de ícone de 28 × 28 pt, o que a mantém numa linha até cerca de 470 pt) e, se ainda não couber, quebra em duas cápsulas: exposição em cima; gravar, lente, áudio e janela embaixo, 8 pt entre elas.

Popovers têm 340 pt de largura, 18 pt de respiro e 14 a 16 pt entre blocos. Grades de opção usam 6 pt de vão. Cartões centrais têm 22 pt de respiro e ficam a 32 pt das bordas.

### Named Rules
**The Edges Rule.** Status mora nos cantos de cima e controle na base; o centro do quadro fica com o vídeo. Nada novo entra no centro sem pedido do usuário.

## Elevation & Depth

Sem sombras. A profundidade vem do material: tudo o que flutua sobre o vídeo usa Liquid Glass regular do macOS 26 (`glassEffect`), interativo quando o elemento responde a clique, e cai para `ultraThinMaterial` em versões anteriores do sistema. Popovers e diálogos são os nativos do macOS. Sobre o próprio vídeo, legibilidade vem de traço duplo, não de sombra: a grade é branca 55% de 0,75 pt sobre preto 30% de 2 pt, e a mira de foco é amarela de 1,5 pt sobre preto 40% de 3 pt.

### Named Rules
**The Glass Only Rule.** Uma superfície sobre o vídeo é vidro do sistema ou não existe. Sem fundos opacos, sem sombras desenhadas à mão, sem bordas decorativas no vidro.

## Shapes

A forma dominante é a cápsula: as duas cápsulas de status, a barra de controles e o realce de cada item da barra, que é cápsula concêntrica à borda da barra. Cartões (estados sem vídeo, atalhos, cápsula de gravação empilhada) usam cantos contínuos de 18 pt. Opções dos popovers têm 7 pt contínuos, teclas desenhadas 5 pt e marcas pequenas (miniatura da grade, quadrado de parar gravação) 3 pt. Círculos ficam para o que é círculo: o ponto de REC, o botão de gravar e os anéis das lentes.

## Components

### Buttons
- **Item da barra:** sem fundo em repouso, a cápsula clareia com o estado (12% sob o mouse, 20% ligado ou com popover aberto, 28% pressionado); texto sempre primário, cursor de link. Ícones da barra em 15 pt medium num alvo de 34 × 34 pt (28 × 28 pt na barra apertada; o alvo é sempre quadrado, para a marca de ligado ser um círculo).
- **Gravar:** disco vermelho de 30 pt dentro de anel branco 90% de 2 pt e 36 pt, alvo de 44 pt; gravando, ganha um quadrado branco de 11 pt. O disco é renderizado em grupo próprio para a vibrancy do vidro não desbotar o vermelho. Falha deixa o disco a 50%; pendente mostra indicador de progresso branco.
- **Ação dentro de popover** ("Medir o branco agora", "Focar agora", "Zerar"): botão `.bordered` do sistema, separado das grades de escolha.

### Chips
- **Opção de popover:** cantos de 7 pt, altura mínima 28 pt, respiro lateral 8 pt (3 pt nas lentes), branco 8% em repouso. Escolhida, preenche com a cor de destaque e o texto fica branco. A única exceção de cor é "Sem áudio", que preenche em vermelho quando escolhida, porque aí é alarme; fica separada no fim da lista por um divisor e pede confirmação se a câmera está gravando.
- **Marca de sem cintilação:** lâmpada do SF Symbols (`lightbulb.fill`, 9 pt, secundária) ao lado do valor de shutter, a mesma na legenda do próprio popover.

### Cards / Containers
- **Cápsula de status:** vidro em cápsula, respiro 8 × 14 pt (10 pt na janela estreita).
- **Cartão central:** vidro com cantos de 18 pt, respiro 22 pt, título em title3 semibold com indicador de progresso e detalhe em callout secundário.
- **Popover:** nativo, seta para cima, 340 pt; nota de falha em vermelho com triângulo no fim.

### Inputs / Fields
- Sliders, segmentados e switches são os nativos do macOS. O slider de câmera segue o valor confirmado quando parado e envia enquanto é arrastado; o passo vale no envio, sem marcas no trilho.

### Value Item
Rótulo de 10 pt secundário em cima, valor de 15 pt semibold embaixo, 1 pt entre os dois e respiro 5 × 10 pt. Pendente mostra um indicador mini ao lado até a câmera confirmar (prazo de 3 s); falha deixa o valor vermelho. Rótulo pode carregar contexto curto com ponto médio ("ISO · auto", "Lente · 13 mm").

### Audio Meter
O medidor do Blackmagic Camera: uma barra por canal sobre o trilho com as três zonas a 24% de opacidade, verde de -60 até -20 dBFS, amarelo até -9, vermelho até 0. A barra acesa toma a cor da zona e a marca de pico (1,5 pt; 2,5 pt no grande) segura 1 s e cai a 20 dB em 1,7 s, como o PPM tipo I. A escala comprime abaixo de -20 (metade da largura de -20 a 0). Redesenha a 30 Hz e apaga se o som parou há mais de 0,5 s. Pequeno na cápsula (96 × 14 pt, 2 pt entre canais); grande no popover de áudio (46 pt de altura, L e R, marcas e números de -40 a 0).

### Motion
A barra aparece e some com fade de 0,25 s ease-out e desliza 12 pt; some 3 s depois do último movimento do mouse, nunca com popover aberto, e o cursor some junto. A mira de foco (56 pt, quatro cantos de 12 pt) fica 1 s e apaga em 0,4 s ease-out. A tela de atalhos entra e sai por opacidade.

### Tally e estados do quadro
Gravando, uma borda vermelha de 3 pt contorna o quadro. Sem câmera, a borda some, porque o estado é desconhecido. Quadro parado escurece com véu preto 60% até o vídeo voltar.

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
