// Servidor local del teleprompter, dentro de la app. No usa internet: la computadora sirve
// la pantalla, y el teléfono entra por el mismo Wi-Fi a /control con la clave del QR.
// Los mensajes viajan así: el teléfono manda órdenes a la pantalla, y la pantalla le manda
// su estado al teléfono. Nunca al revés, así nadie recibe su propio eco.
//
// Hace exactamente lo mismo que app/servidor.js (la versión anterior), y pasa sus mismas
// pruebas (app/pruebas/servidor.test.js con TP_SWIFT apuntando a este programa).

import Foundation
import Network
import CoreImage

final class Servidor {
    static let puertoBase: UInt16 = 48650
    static let maxCuerpo = 1024 * 1024      // el guion más largo cabe de sobra en 1 MB
    static let maxMensaje = 8 * 1024
    static let topicos: [String: [String]] = ["control": ["cmd", "hola"], "pantalla": ["estado"]]

    let carpeta: URL
    let pagina: URL
    private(set) var clave = ""
    private(set) var puerto: UInt16 = 0

    private let cola = DispatchQueue(label: "teleprompter.servidor")
    private var listener: NWListener?
    private var clientes: [ObjectIdentifier: (conn: NWConnection, rol: String)] = [:]
    private var latido: DispatchSourceTimer?

    private var archivoAjustes: URL { carpeta.appendingPathComponent("ajustes.json") }
    private var archivoClave: URL { carpeta.appendingPathComponent("clave.txt") }

    init(carpeta: URL, pagina: URL) {
        self.carpeta = carpeta
        self.pagina = pagina
    }

    // MARK: - Arrancar y parar

    /// Prende el servidor. Si el puerto está ocupado, prueba los diez siguientes.
    func arrancar(desde base: UInt16 = Servidor.puertoBase) throws -> UInt16 {
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        // La clave va en el QR. Sin ella, alguien más en el mismo Wi-Fi no puede controlar.
        let leida = (try? String(contentsOf: archivoClave, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if leida.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil {
            clave = leida
        } else {
            var bytes = [UInt8](repeating: 0, count: 12)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            clave = bytes.map { String(format: "%02x", $0) }.joined()
            try Data(clave.utf8).write(to: archivoClave, options: .atomic)
        }

        var ultimoError: Error = NSError(domain: "Teleprompter", code: 1)
        for p in base...(base + 10) {
            do {
                try escuchar(en: p)
                puerto = p
                empezarLatido()
                return p
            } catch { ultimoError = error }
        }
        throw ultimoError
    }

    /// ¿Está libre el puerto para todos? NWListener a veces "logra" abrir un puerto que ya ocupa
    /// otro programa (por la vía de la red nueva), y entonces los dos se pelean las conexiones.
    /// Se prueba primero de la forma clásica, que sí falla si está ocupado.
    private static func puertoLibre(_ p: UInt16) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        // Sin esto, el puerto se ve "ocupado" unos segundos después de cerrar la app (las
        // conexiones viejas tardan en soltarlo) y la app se mudaría de puerto; el teléfono, que
        // guardó la dirección anterior, ya no conectaría. Con esto solo falla si alguien lo está usando.
        var uno: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &uno, socklen_t(MemoryLayout<Int32>.size))
        var dir = sockaddr_in()
        dir.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dir.sin_family = sa_family_t(AF_INET)
        dir.sin_port = p.bigEndian
        dir.sin_addr = in_addr(s_addr: INADDR_ANY)
        let r = withUnsafePointer(to: &dir) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    private func escuchar(en p: UInt16) throws {
        guard Servidor.puertoLibre(p) else { throw NSError(domain: "Teleprompter", code: 48, userInfo: [NSLocalizedDescriptionKey: "ocupado"]) }
        let parametros = NWParameters.tcp
        parametros.allowLocalEndpointReuse = true   // mismo motivo que en puertoLibre()
        let l = try NWListener(using: parametros, on: NWEndpoint.Port(rawValue: p)!)
        let listo = DispatchSemaphore(value: 0)
        var fallo: Error?
        l.stateUpdateHandler = { estado in
            switch estado {
            case .ready: listo.signal()
            case .failed(let e): fallo = e; listo.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.atender(c) }
        l.start(queue: cola)
        if listo.wait(timeout: .now() + 3) == .timedOut { l.cancel(); throw NSError(domain: "Teleprompter", code: 2) }
        if let fallo { l.cancel(); throw fallo }
        listener = l
    }

    func parar() {
        cola.sync {
            latido?.cancel()
            for (_, c) in clientes { c.conn.cancel() }
            clientes.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    // Un renglón vacío cada 15 s para que ni el teléfono ni el Wi-Fi corten la conexión callada.
    private func empezarLatido() {
        let t = DispatchSource.makeTimerSource(queue: cola)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for (_, c) in self.clientes { c.conn.send(content: Data(": latido\n\n".utf8), completion: .idempotent) }
        }
        t.resume()
        latido = t
    }

    // MARK: - Leer la petición

    private struct Peticion {
        var metodo = ""
        var ruta = ""
        var consulta: [String: String] = [:]
        var cuerpo = Data()
        var local = false
    }

    private enum Lectura { case falta, lista(Peticion), muyGrande, rota }

    private func atender(_ c: NWConnection) {
        c.start(queue: cola)
        leer(c, Data())
    }

    private func leer(_ c: NWConnection, _ acumulado: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] datos, _, fin, error in
            guard let self else { return }
            var buf = acumulado
            if let datos { buf.append(datos) }
            switch self.interpretar(buf, c) {
            case .lista(let p): self.manejar(c, p)
            case .muyGrande: self.responder(c, 413, json: ["error": "grande"])
            case .rota: self.responder(c, 400, json: ["error": "peticion"])
            case .falta:
                if fin || error != nil { c.cancel() } else { self.leer(c, buf) }
            }
        }
    }

    private func interpretar(_ buf: Data, _ c: NWConnection) -> Lectura {
        guard let fin = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > 16384 ? .rota : .falta
        }
        guard let cabeza = String(data: buf[buf.startIndex..<fin.lowerBound], encoding: .utf8) else { return .rota }
        let lineas = cabeza.components(separatedBy: "\r\n")
        let primera = lineas[0].split(separator: " ")
        guard primera.count >= 2 else { return .rota }
        var largo = 0
        var enPedazos = false
        for l in lineas.dropFirst() {
            let partes = l.split(separator: ":", maxSplits: 1)
            guard partes.count == 2 else { continue }
            let nombre = partes[0].lowercased(), v = partes[1].trimmingCharacters(in: .whitespaces).lowercased()
            if nombre == "content-length" { largo = Int(v) ?? 0 }
            if nombre == "transfer-encoding" && v.contains("chunked") { enPedazos = true }
        }
        // Un cuerpo demasiado grande se rechaza antes de leerlo.
        if largo > Servidor.maxCuerpo { return .muyGrande }
        let resto = Data(buf[fin.upperBound...])
        let cuerpo: Data
        if enPedazos {
            // Algunos programas mandan el cuerpo en pedazos en vez de decir su largo; se arma aquí.
            switch Servidor.juntarPedazos(resto) {
            case .falta: return .falta
            case .rota: return .rota
            case .muyGrande: return .muyGrande
            case .lista(let d): cuerpo = d
            }
        } else {
            if resto.count < largo { return .falta }
            cuerpo = resto.prefix(largo)
        }

        var p = Peticion()
        p.metodo = String(primera[0])
        let destino = String(primera[1])
        let comps = URLComponents(string: "http://x" + destino)
        p.ruta = comps?.path ?? destino
        for item in comps?.queryItems ?? [] { p.consulta[item.name] = item.value ?? "" }
        p.cuerpo = cuerpo
        p.local = esLocal(c)
        return .lista(p)
    }

    private enum Pedazos { case falta, rota, muyGrande, lista(Data) }

    /// Cada pedazo es "<largo en hexadecimal>\r\n<datos>\r\n"; un pedazo de largo 0 cierra.
    private static func juntarPedazos(_ d: Data) -> Pedazos {
        var salida = Data()
        var i = d.startIndex
        let salto = Data("\r\n".utf8)
        while true {
            guard let fl = d.range(of: salto, in: i..<d.endIndex) else { return .falta }
            guard let linea = String(data: d[i..<fl.lowerBound], encoding: .ascii),
                  let n = Int(linea.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) else { return .rota }
            let inicio = fl.upperBound
            if n == 0 { return .lista(salida) }
            if salida.count + n > maxCuerpo { return .muyGrande }
            guard d.distance(from: inicio, to: d.endIndex) >= n + 2 else { return .falta }
            let finDatos = d.index(inicio, offsetBy: n)
            salida.append(d[inicio..<finDatos])
            i = d.index(finDatos, offsetBy: 2)
        }
    }

    private func esLocal(_ c: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = c.endpoint else { return false }
        switch host {
        case .ipv4(let a): return a == .loopback
        case .ipv6(let a):
            if a == .loopback { return true }
            let s = "\(a)"
            return s.hasSuffix("127.0.0.1")
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    // MARK: - Las rutas (las mismas que app/servidor.js)

    private func manejar(_ c: NWConnection, _ p: Peticion) {
        let conClave = p.consulta["k"] == clave

        if p.metodo == "GET" && (p.ruta == "/" || p.ruta == "/control") {
            // La pantalla solo se abre en esta computadora; el teléfono solo entra al control con su clave.
            if p.ruta == "/" && !p.local { return responder(c, 403, texto: "Esta página solo abre en la computadora.") }
            if p.ruta == "/control" && !conClave { return responder(c, 403, texto: "Vuelve a escanear el código de la computadora.") }
            let html = (try? Data(contentsOf: pagina)) ?? Data()
            return responder(c, 200, datos: html, tipo: "text/html; charset=utf-8")
        }

        if p.ruta == "/api/ajustes" {
            if !p.local { return responder(c, 403, json: ["error": "solo local"]) }
            if p.metodo == "GET" {
                // Se devuelve el archivo tal cual si está sano; si está dañado, como si no hubiera nada.
                if let d = try? Data(contentsOf: archivoAjustes),
                   (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] != nil {
                    return responder(c, 200, datos: d, tipo: "application/json; charset=utf-8")
                }
                return responder(c, 200, json: [String: Any]())
            }
            if p.metodo == "POST" {
                guard let obj = try? JSONSerialization.jsonObject(with: p.cuerpo, options: [.fragmentsAllowed]) else {
                    return responder(c, 400, json: ["error": "no es JSON"])
                }
                guard obj is [String: Any] else { return responder(c, 400, json: ["error": "forma"]) }
                // .atomic escribe a un archivo aparte y luego lo cambia de nombre: si la app se
                // cierra a media escritura, el guion anterior queda entero.
                do { try p.cuerpo.write(to: archivoAjustes, options: .atomic) }
                catch { return responder(c, 500, json: ["error": "falla"]) }
                return responder(c, 200, json: ["ok": true])
            }
        }

        // El teléfono lee el guion para elegir desde qué palabra empezar. Solo el texto:
        // los demás ajustes son de la computadora.
        if p.metodo == "GET" && p.ruta == "/api/guion" {
            if !p.local && !conClave { return responder(c, 403, json: ["error": "clave"]) }
            var txt = ""
            if let d = try? Data(contentsOf: archivoAjustes),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let t = o["texto"] as? String { txt = t }
            return responder(c, 200, json: ["texto": txt])
        }

        if p.metodo == "GET" && p.ruta == "/api/qr" {
            if !p.local { return responder(c, 403, json: ["error": "solo local"]) }
            guard let ip = Servidor.ipLocal() else { return responder(c, 200, json: ["error": "sin-red"]) }
            let liga = "http://\(ip):\(puerto)/control?k=\(clave)"
            guard let png = Servidor.codigoQR(liga) else { return responder(c, 500, json: ["error": "falla"]) }
            return responder(c, 200, json: ["liga": liga, "imagen": "data:image/png;base64," + png.base64EncodedString()])
        }

        if p.metodo == "GET" && p.ruta == "/api/eventos" {
            let rol = p.consulta["rol"] ?? ""
            if rol == "pantalla" && !p.local { return responder(c, 403, json: ["error": "solo local"]) }
            if rol == "control" && !conClave { return responder(c, 403, json: ["error": "clave"]) }
            if rol != "pantalla" && rol != "control" { return responder(c, 400, json: ["error": "rol"]) }
            let cabeza = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\nretry: 1500\n\n"
            c.send(content: Data(cabeza.utf8), completion: .idempotent)
            let id = ObjectIdentifier(c)
            clientes[id] = (c, rol)
            // Cuando el otro lado cierra, se le quita de la lista.
            c.stateUpdateHandler = { [weak self] estado in
                switch estado {
                case .failed, .cancelled: self?.quitar(id)
                default: break
                }
            }
            esperarCierre(c, id)
            avisarTelefonos()
            return
        }

        if p.metodo == "POST" && p.ruta == "/api/enviar" {
            let rol = p.consulta["rol"] ?? ""
            if rol == "pantalla" && !p.local { return responder(c, 403, json: ["error": "solo local"]) }
            if rol == "control" && !conClave { return responder(c, 403, json: ["error": "clave"]) }
            guard let permitidos = Servidor.topicos[rol] else { return responder(c, 400, json: ["error": "rol"]) }
            if p.cuerpo.count > Servidor.maxMensaje { return responder(c, 413, json: ["error": "mensaje"]) }
            guard let m = (try? JSONSerialization.jsonObject(with: p.cuerpo, options: [.fragmentsAllowed])) as? [String: Any] else {
                return responder(c, 400, json: ["error": "mensaje"])
            }
            guard let topic = m["topic"] as? String, permitidos.contains(topic) else {
                return responder(c, 400, json: ["error": "tema"])
            }
            mandar(a: rol == "control" ? "pantalla" : "control", topic: topic, data: m["data"] ?? NSNull())
            return responder(c, 200, json: ["ok": true])
        }

        responder(c, 404, json: ["error": "no existe"])
    }

    // MARK: - Eventos en vivo

    private func esperarCierre(_ c: NWConnection, _ id: ObjectIdentifier) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, fin, error in
            if fin || error != nil { c.cancel(); self?.quitar(id) }
            else { self?.esperarCierre(c, id) }
        }
    }

    private func quitar(_ id: ObjectIdentifier) {
        if clientes.removeValue(forKey: id) != nil { avisarTelefonos() }
    }

    private func mandar(a rolDestino: String, topic: String, data: Any) {
        guard let cuerpo = try? JSONSerialization.data(withJSONObject: ["topic": topic, "data": data], options: [.fragmentsAllowed]),
              let s = String(data: cuerpo, encoding: .utf8) else { return }
        let linea = Data("data: \(s)\n\n".utf8)
        for (_, c) in clientes where c.rol == rolDestino { c.conn.send(content: linea, completion: .idempotent) }
    }

    private func avisarTelefonos() {
        let n = clientes.values.filter { $0.rol == "control" }.count
        mandar(a: "pantalla", topic: "telefonos", data: n)
    }

    // MARK: - Contestar

    private func responder(_ c: NWConnection, _ codigo: Int, json: Any) {
        let d = (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        responder(c, codigo, datos: d, tipo: "application/json; charset=utf-8")
    }

    private func responder(_ c: NWConnection, _ codigo: Int, texto: String) {
        responder(c, codigo, datos: Data(texto.utf8), tipo: "text/plain; charset=utf-8")
    }

    private func responder(_ c: NWConnection, _ codigo: Int, datos: Data, tipo: String) {
        let razones = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 500: "Internal Server Error"]
        let cabeza = "HTTP/1.1 \(codigo) \(razones[codigo] ?? "OK")\r\nContent-Type: \(tipo)\r\nContent-Length: \(datos.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var todo = Data(cabeza.utf8)
        todo.append(datos)
        c.send(content: todo, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: - Red y QR

    /// La dirección de la computadora en el Wi-Fi. Se vuelve a calcular cada vez,
    /// porque la red puede cambiar con la app abierta. en0 es el Wi-Fi en casi todas las Mac.
    static func ipLocal() -> String? {
        var candidatas: [(nombre: String, ip: String)] = []
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primero = lista else { return nil }
        defer { freeifaddrs(lista) }
        var p: UnsafeMutablePointer<ifaddrs>? = primero
        while let actual = p {
            let i = actual.pointee
            p = i.ifa_next
            guard let dir = i.ifa_addr, dir.pointee.sa_family == UInt8(AF_INET) else { continue }
            let banderas = Int32(i.ifa_flags)
            if banderas & IFF_UP == 0 || banderas & IFF_LOOPBACK != 0 { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(dir, socklen_t(dir.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) != 0 { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            candidatas.append((String(cString: i.ifa_name), ip))
        }
        return (candidatas.first { $0.nombre == "en0" } ?? candidatas.first)?.ip
    }

    static func codigoQR(_ texto: String) -> Data? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(texto.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let base = f.outputImage else { return nil }
        // Se agranda sin suavizar, para que los cuadritos salgan nítidos y el teléfono lo lea a la primera.
        let escala = max(1, (440 / base.extent.width).rounded(.down))
        let grande = base.samplingNearest().transformed(by: CGAffineTransform(scaleX: escala, y: escala))
        return CIContext().pngRepresentation(of: grande, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
