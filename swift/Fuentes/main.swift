// La app de Mac del teleprompter: una ventana que muestra la pantalla (pantalla.html, la misma
// de antes) y el servidor local para que el teléfono la controle por el Wi-Fi. Sin internet.
//
// También se puede correr solo el servidor, sin ventana, para las pruebas:
//   Teleprompter --solo-servidor --datos <carpeta> --puerto <n> [--pagina <archivo>]

import AppKit
import WebKit

// MARK: - Modo de pruebas: solo el servidor

let argumentos = CommandLine.arguments
func valor(_ nombre: String) -> String? {
    guard let i = argumentos.firstIndex(of: nombre), i + 1 < argumentos.count else { return nil }
    return argumentos[i + 1]
}

if argumentos.contains("--solo-servidor") {
    let datos = URL(fileURLWithPath: valor("--datos") ?? FileManager.default.currentDirectoryPath)
    let pagina = valor("--pagina").map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.url(forResource: "pantalla", withExtension: "html")!
    let s = Servidor(carpeta: datos, pagina: pagina)
    do {
        let p = try s.arrancar(desde: UInt16(valor("--puerto") ?? "") ?? Servidor.puertoBase)
        print("listo \(p)")
        fflush(stdout)
    } catch {
        FileHandle.standardError.write(Data("no se pudo abrir el servidor: \(error)\n".utf8))
        exit(1)
    }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()
}

// MARK: - La app con ventana

final class Delegado: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var ventana: NSWindow!
    var web: WKWebView!
    var servidor: Servidor!
    var base = ""
    var yaGuardo = false
    // Que la pantalla no se apague mientras la app está abierta.
    var actividad: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        armarMenu()

        let soporte = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Misma carpeta que usaba la versión anterior: el guion y la clave del QR se conservan.
        let carpeta = soporte.appendingPathComponent("Teleprompter")
        servidor = Servidor(carpeta: carpeta, pagina: Bundle.main.url(forResource: "pantalla", withExtension: "html")!)
        do {
            let p = try servidor.arrancar()
            base = "http://127.0.0.1:\(p)/"
        } catch {
            let a = NSAlert()
            a.messageText = "No se pudo abrir el teleprompter"
            a.informativeText = "Otro programa está usando la conexión que necesita. Cierra otras copias de la app y vuelve a abrirla."
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        let conf = WKWebViewConfiguration()
        conf.preferences.isElementFullscreenEnabled = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: conf)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // sin destello blanco al abrir

        // El monitor donde se usa tiene una raya justo a la mitad, y la pantalla deja libre la
        // mitad de la VENTANA. Para que las dos mitades coincidan, la ventana abre ocupando todo.
        let marco = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 760)
        ventana = NSWindow(contentRect: marco, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        ventana.title = "Teleprompter"
        ventana.backgroundColor = NSColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)
        ventana.contentView = web
        ventana.delegate = self
        ventana.collectionBehavior = [.fullScreenPrimary]
        ventana.setFrame(marco, display: true)
        ventana.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        actividad = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Teleprompter abierto")
        web.load(URLRequest(url: URL(string: base)!))
    }

    // Nada se abre dentro de la ventana fuera del teleprompter.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = a.request.url?.absoluteString ?? ""
        decisionHandler(url.hasPrefix(base) || url == "about:blank" ? .allow : .cancel)
    }

    // Si la página se cae (pasa a veces con WebKit), se vuelve a cargar sola.
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        w.load(URLRequest(url: URL(string: base)!))
    }

    // MARK: Cerrar sin perder lo último que se escribió

    private func guardarYLuego(_ siguiente: @escaping () -> Void) {
        if yaGuardo || web == nil { siguiente(); return }
        var hecho = false
        let terminar = { if !hecho { hecho = true; self.yaGuardo = true; siguiente() } }
        web.callAsyncJavaScript("if (window.__guardarYa) { await window.__guardarYa(); } return true;", arguments: [:], in: nil, in: .page) { _ in terminar() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { terminar() }
    }

    func windowShouldClose(_ s: NSWindow) -> Bool {
        if yaGuardo { return true }
        guardarYLuego { NSApp.terminate(nil) }
        return false
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if yaGuardo { return .terminateNow }
        guardarYLuego { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ n: Notification) {
        servidor?.parar()
        if let actividad { ProcessInfo.processInfo.endActivity(actividad) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // Sin el menú Edición, en una app de Mac no funcionan copiar y pegar en el guion.
    private func armarMenu() {
        let principal = NSMenu()

        let app = NSMenuItem()
        let menuApp = NSMenu()
        menuApp.addItem(withTitle: "Ocultar Teleprompter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menuApp.addItem(.separator())
        menuApp.addItem(withTitle: "Salir de Teleprompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = menuApp
        principal.addItem(app)

        let edicion = NSMenuItem()
        let menuEd = NSMenu(title: "Edición")
        menuEd.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let rehacer = menuEd.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        rehacer.keyEquivalentModifierMask = [.command, .shift]
        menuEd.addItem(.separator())
        menuEd.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menuEd.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menuEd.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menuEd.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edicion.submenu = menuEd
        principal.addItem(edicion)

        let vista = NSMenuItem()
        let menuVista = NSMenu(title: "Ver")
        let completa = menuVista.addItem(withTitle: "Pantalla completa", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        completa.keyEquivalentModifierMask = [.command, .control]
        vista.submenu = menuVista
        principal.addItem(vista)

        let ventanaMenu = NSMenuItem()
        let menuVentana = NSMenu(title: "Ventana")
        menuVentana.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menuVentana.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        ventanaMenu.submenu = menuVentana
        principal.addItem(ventanaMenu)

        NSApp.mainMenu = principal
    }
}

// Una sola copia abierta: una segunda pelearía por la conexión y por el archivo del guion.
let mio = Bundle.main.bundleIdentifier ?? ""
if !mio.isEmpty {
    let otras = NSRunningApplication.runningApplications(withBundleIdentifier: mio).filter { $0 != NSRunningApplication.current }
    if let otra = otras.first {
        otra.activate()
        exit(0)
    }
}

let app = NSApplication.shared
let delegado = Delegado()
app.delegate = delegado
app.setActivationPolicy(.regular)
app.run()
