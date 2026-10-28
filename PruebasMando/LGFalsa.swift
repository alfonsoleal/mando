import Foundation
import Network
@testable import Mando

/// Una tele LG de mentira: WebSocket seguro con certificado autofirmado, como
/// la real, y SSAP. Si el teléfono no trae una llave que conozca, «pregunta en
/// pantalla» y espera a que la prueba llame a `aceptar()` o `rechazar()`.
nonisolated final class LGFalsa: @unchecked Sendable {
    private let candado = NSLock()
    private let cola = DispatchQueue(label: "lg-falsa")
    private var oyente: NWListener?
    private var conexiones: [NWConnection] = []
    private var suscritas: [(NWConnection, String, String)] = []
    private var preguntando: NWConnection?
    private var llaves: Set<String> = []

    private(set) var volumen = 19
    private(set) var silencio = false
    private(set) var apagada = false
    private(set) var preguntas = 0

    func arrancar() async throws -> UInt16 {
        let identidad = try Certificado.identidad(nombre: "LGFalsa")
        let parametros = TLS.parametros(identidad: identidad)
        parametros.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let o = try NWListener(using: parametros, on: .any)
        o.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.candado.withLock { self.conexiones.append(c) }
            c.start(queue: self.cola)
            self.leer(c)
        }
        oyente = o
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let una = Unico()
            o.stateUpdateHandler = { e in
                switch e {
                case .ready: if una.primero() { k.resume() }
                case .failed(let err): if una.primero() { k.resume(throwing: err) }
                default: break
                }
            }
            o.start(queue: cola)
        }
        return o.port!.rawValue
    }

    func apagar() {
        oyente?.cancel()
        candado.withLock { conexiones.forEach { $0.cancel() } }
    }

    /// Alguien aceptó con el control de la tele.
    func aceptar() {
        let llave = UUID().uuidString
        guard let c = candado.withLock({ () -> NWConnection? in
            llaves.insert(llave)
            defer { preguntando = nil }
            return preguntando
        }) else { return }
        mandar(c, ["type": "registered", "id": "registro", "payload": ["client-key": llave]])
    }

    func rechazar() {
        guard let c = candado.withLock({ () -> NWConnection? in
            defer { preguntando = nil }
            return preguntando
        }) else { return }
        mandar(c, ["type": "error", "id": "registro", "error": "403 User denied access"])
    }

    /// Como subir el volumen con el control de la LG.
    func cambiarVolumenConSuControl(_ v: Int) {
        candado.withLock { volumen = v }
        avisarVolumen()
    }

    // MARK: - Red

    private func leer(_ c: NWConnection) {
        c.receiveMessage { [weak self] datos, _, _, error in
            guard let self, error == nil else { return }
            if let datos, let m = (try? JSONSerialization.jsonObject(with: datos)) as? [String: Any] {
                self.atender(m, c)
            }
            self.leer(c)
        }
    }

    private func mandar(_ c: NWConnection, _ m: [String: Any]) {
        guard let datos = try? JSONSerialization.data(withJSONObject: m) else { return }
        let contexto = NWConnection.ContentContext(identifier: "ssap", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        c.send(content: datos, contentContext: contexto, isComplete: true, completion: .idempotent)
    }

    private func atender(_ m: [String: Any], _ c: NWConnection) {
        let id = m["id"] as? String ?? ""
        let payload = m["payload"] as? [String: Any] ?? [:]
        switch (m["type"] as? String, m["uri"] as? String) {
        case ("register", _):
            let llave = payload["client-key"] as? String
            let conocida = candado.withLock { llave.map(llaves.contains) ?? false }
            if conocida {
                mandar(c, ["type": "registered", "id": id, "payload": ["client-key": llave!]])
            } else {
                candado.withLock { preguntando = c; preguntas += 1 }
                mandar(c, ["type": "response", "id": id, "payload": ["pairingType": "PROMPT", "returnValue": true]])
            }
        case ("subscribe", let uri?):
            candado.withLock { suscritas.append((c, id, uri)) }
            if uri.hasSuffix("getVolume") { avisarVolumen() }
            if uri.hasSuffix("getPowerState") { mandar(c, ["type": "response", "id": id, "payload": ["state": "Active"]]) }
        case ("request", let uri?):
            candado.withLock {
                switch uri {
                case "ssap://audio/volumeUp": volumen = min(volumen + 1, 100)
                case "ssap://audio/volumeDown": volumen = max(volumen - 1, 0)
                case "ssap://audio/setVolume": volumen = payload["volume"] as? Int ?? volumen
                case "ssap://audio/setMute": silencio = payload["mute"] as? Bool ?? silencio
                case "ssap://system/turnOff": apagada = true
                default: break
                }
            }
            mandar(c, ["type": "response", "id": id, "payload": ["returnValue": true]])
            if uri.hasPrefix("ssap://audio/") { avisarVolumen() }
        default:
            break
        }
    }

    /// Como las LG recientes: el volumen viene dentro de «volumeStatus».
    private func avisarVolumen() {
        let (v, s, destinos) = candado.withLock { (volumen, silencio, suscritas.filter { $0.2.hasSuffix("getVolume") }) }
        for (c, id, _) in destinos {
            mandar(c, ["type": "response", "id": id, "payload": ["volumeStatus": ["volume": v, "muteStatus": s, "maxVolume": 100]]])
        }
    }
}
