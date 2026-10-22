import AppKit

// App mínimo: só existe para o Xcode gerar o perfil de desenvolvimento com a permissão de
// instalar extensões de sistema e embutir a extensão assinada. O app de verdade é o bmonitor,
// montado pelo `Webcam/build-dev.sh` com a extensão e o perfil tirados daqui.
let app = NSApplication.shared
app.run()
