import Foundation
import Network

/// Habla con una tele LG con webOS por SSAP: mensajes JSON sobre un WebSocket
/// seguro en el puerto 3001. La primera vez la tele pregunta en pantalla si
/// deja entrar a Mando; al aceptar entrega una llave que se guarda en el
/// Llavero y las siguientes veces ya no pregunta.
///
/// Los permisos van sin la firma larga que usan otras apps: con la LG con
/// que se probó el registro sencillo funciona para volumen y encendido.
actor ControladorLG: Controlador {
    nonisolated let reportes: AsyncStream<Reporte>
    private nonisolated let avisar: AsyncStream<Reporte>.Continuation

    private var host: String?
    private let puerto: UInt16
    private let cuenta: String
    static let servicio = "mx.alfonsoleal.mando.lg"

    private var conexion: NWConnection?
    private var lectura: Task<Void, Never>?
    private var registrada = false
    private var pendientes: [String: CheckedContinuation<Data, Error>] = [:]
    private var siguiente = 1
    private var enCurso: Task<Void, Error>?
    private let buscarSiFalla: Bool

    init(host: String? = nil, puerto: UInt16 = 3001, cuenta: String = "LG", buscarSiFalla: Bool = true) {
        self.host = host
        self.puerto = puerto
        self.buscarSiFalla = buscarSiFalla
        self.cuenta = cuenta
        (reportes, avisar) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    // MARK: - Conectar

    func conectar() async throws {
        if let conexion, conexion.state == .ready {
            if registrada { return }
            throw ErrorControl.esperandoPermiso
        }
        // Una sola conexión a la vez: la segunda espera a la primera.
        if let enCurso { return try await enCurso.value }
        let t = Task { try await abrir() }
        enCurso = t
        defer { enCurso = nil }
        try await t.value
    }

    private func abrir() async throws {
        soltar()
        let guardado = host
        if host == nil { host = await BuscadorRed.buscar(puertos: [3000, 3001]) }
        guard let host, let url = URL(string: "wss://\(host):\(puerto)") else { throw ErrorControl.lgNoEncontrada }

        let parametros = TLS.parametros(identidad: nil)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        parametros.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let nueva: NWConnection
        do {
            nueva = try await TCP.conectar(a: .url(url), limite: .seconds(4), parametros: parametros)
        } catch where guardado != nil && buscarSiFalla {
            // El router le dio otra IP: se busca otra vez.
            self.host = nil
            return try await abrir()
        } catch {
            throw ErrorControl.sinRespuesta("La tele LG")
        }
        avisar.yield(.direccion(host: host, puerto: puerto))
        conexion = nueva
        leer(nueva)

        let llave = Llavero.leer(ControladorLG.servicio, cuenta).map { String(decoding: $0, as: UTF8.self) }
        var registro: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": ["manifestVersion": 1, "appVersion": "1.0", "permissions": ControladorLG.permisos],
        ]
        if let llave { registro["client-key"] = llave }
        let respuesta: [String: Any]
        do {
            respuesta = try await pedir(tipo: "register", id: "registro", uri: nil, payload: registro, limite: .seconds(6))
        } catch {
            soltar()
            throw error
        }
        if respuesta["type"] as? String == "registered" {
            try await alRegistrarse(respuesta)
        } else {
            // La tele está preguntando. La respuesta «registered» llegará sola
            // cuando alguien acepte; la lectura la atiende.
            throw ErrorControl.esperandoPermiso
        }
    }

    private func alRegistrarse(_ m: [String: Any]) async throws {
        if let llave = (m["payload"] as? [String: Any])?["client-key"] as? String {
            Llavero.guardar(Data(llave.utf8), ControladorLG.servicio, cuenta)
        }
        registrada = true
        avisar.yield(.listo)
        // Suscripciones: la tele avisa cada cambio, también los que se hacen
        // con su propio control.
        try enviar(tipo: "subscribe", id: "volumen", uri: "ssap://audio/getVolume", payload: nil)
        try enviar(tipo: "subscribe", id: "energia", uri: "ssap://com.webos.service.tvpower/power/getPowerState", payload: nil)
    }

    // MARK: - Órdenes

    func mandar(_ orden: Orden) async throws {
        try await conectar()
        let (uri, payload): (String, [String: Any]?)
        switch orden {
        case .subirVolumen: (uri, payload) = ("ssap://audio/volumeUp", nil)
        case .bajarVolumen: (uri, payload) = ("ssap://audio/volumeDown", nil)
        case .volumen(let v): (uri, payload) = ("ssap://audio/setVolume", ["volume": min(max(v, 0), 100)])
        case .silencio(let si): (uri, payload) = ("ssap://audio/setMute", ["mute": si])
        case .encender(false): (uri, payload) = ("ssap://system/turnOff", nil)
        case .encender(true):
            // Apagada, la LG sólo despierta con un paquete por broadcast (Wake
            // on LAN), que en iOS pide un permiso que Apple aprueba a mano.
            throw ErrorControl.pendiente("Prende la LG con su control o con el Apple TV: apagada no escucha por la red.")
        default:
            throw ErrorControl.noSoportada(orden, .lg)
        }
        let id = "orden-\(siguiente)"
        siguiente += 1
        let respuesta = try await pedir(tipo: "request", id: id, uri: uri, payload: payload, limite: .seconds(4))
        guard (respuesta["payload"] as? [String: Any])?["returnValue"] as? Bool == true else {
            throw ErrorControl.sinRespuesta("La tele LG")
        }
    }

    // MARK: - Red

    private func pedir(tipo: String, id: String, uri: String?, payload: [String: Any]?, limite: Duration) async throws -> [String: Any] {
        let datos = try ControladorLG.mensaje(tipo: tipo, id: id, uri: uri, payload: payload)
        let respuesta = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            pendientes[id] = c
            mandarTexto(datos)
            Task { [weak self] in
                try? await Task.sleep(for: limite)
                await self?.vencer(id)
            }
        }
        return (try? JSONSerialization.jsonObject(with: respuesta)) as? [String: Any] ?? [:]
    }

    private func enviar(tipo: String, id: String, uri: String?, payload: [String: Any]?) throws {
        mandarTexto(try ControladorLG.mensaje(tipo: tipo, id: id, uri: uri, payload: payload))
    }

    private func mandarTexto(_ datos: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let contexto = NWConnection.ContentContext(identifier: "ssap", metadata: [meta])
        conexion?.send(content: datos, contentContext: contexto, isComplete: true, completion: .idempotent)
    }

    private func vencer(_ id: String) {
        pendientes.removeValue(forKey: id)?.resume(throwing: ErrorControl.sinRespuesta("La tele LG"))
    }

    private func leer(_ c: NWConnection) {
        lectura = Task {
            while !Task.isCancelled {
                guard let datos = await ControladorLG.recibir(c) else { break }
                await atender(datos)
            }
            soltar()
        }
    }

    private func atender(_ crudo: Data) async {
        guard let m = (try? JSONSerialization.jsonObject(with: crudo)) as? [String: Any] else { return }
        let id = m["id"] as? String ?? ""
        let tipo = m["type"] as? String
        let payload = m["payload"] as? [String: Any] ?? [:]
        switch id {
        case "registro" where pendientes["registro"] == nil:
            // Llega después de que alguien aceptó en la tele (o la rechazó).
            if tipo == "registered" {
                try? await alRegistrarse(m)
            } else if tipo == "error" {
                soltar()
            }
        case "volumen":
            // Las LG recientes mandan el volumen dentro de «volumeStatus».
            let estado = payload["volumeStatus"] as? [String: Any] ?? payload
            if let v = estado["volume"] as? Int { avisar.yield(.volumen(v)) }
            if let silencio = (estado["muted"] ?? estado["muteStatus"]) as? Bool { avisar.yield(.silencio(silencio)) }
        case "energia":
            if let estado = payload["state"] as? String {
                avisar.yield(.encendido(["Active", "Screen Saver"].contains(estado)))
            }
        default:
            // Mientras la tele pregunta, la primera respuesta del registro es
            // «response» con PROMPT: se entrega igual para que conectar() lo sepa.
            if tipo == "error", id != "registro" {
                pendientes.removeValue(forKey: id)?.resume(throwing: ErrorControl.sinRespuesta("La tele LG"))
            } else if tipo == "error" {
                pendientes.removeValue(forKey: id)?.resume(throwing: ErrorControl.permisoRechazado)
            } else {
                pendientes.removeValue(forKey: id)?.resume(returning: crudo)
            }
        }
    }

    private func soltar() {
        lectura?.cancel()
        lectura = nil
        conexion?.cancel()
        conexion = nil
        registrada = false
        for (_, c) in pendientes { c.resume(throwing: ErrorControl.sinRespuesta("La tele LG")) }
        pendientes.removeAll()
    }

    private static func recibir(_ c: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            c.receiveMessage { datos, _, _, error in
                cont.resume(returning: error == nil ? (datos ?? Data()) : nil)
            }
        }
    }

    static func mensaje(tipo: String, id: String, uri: String?, payload: [String: Any]?) throws -> Data {
        var m: [String: Any] = ["type": tipo, "id": id]
        if let uri { m["uri"] = uri }
        if let payload { m["payload"] = payload }
        return try JSONSerialization.data(withJSONObject: m)
    }

    static let permisos = ["CONTROL_AUDIO", "CONTROL_POWER", "READ_POWER_STATE", "CONTROL_INPUT_MEDIA_PLAYBACK"]
}
