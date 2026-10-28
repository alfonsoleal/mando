import Foundation
import Network
@testable import Mando

/// Un TX-NR838 de mentira: escucha eISCP en localhost, guarda su estado y
/// contesta como el real, con el estado nuevo después de cada comando. Así la
/// prueba recorre el camino completo: Casa → ControladorOnkyo → TCP → receptor.
nonisolated final class ReceptorFalso: @unchecked Sendable {
    private let candado = NSLock()
    private let cola = DispatchQueue(label: "receptor-falso")
    private let oyente: NWListener
    private var clientes: [NWConnection] = []
    private(set) var recibidos: [String] = []

    // Estado inicial: prendido, volumen 30, en STRM BOX, modo Direct.
    private var estado = ["PWR": "01", "MVL": "1E", "AMT": "00", "SLI": "11", "LMD": "01"]
    /// Para probar que el lector arma mensajes partidos: cada respuesta se
    /// manda en dos pedazos.
    var partirRespuestas = false

    init() throws {
        oyente = try NWListener(using: .tcp, on: .any)
        oyente.newConnectionHandler = { [weak self] conexion in self?.atender(conexion) }
    }

    func arrancar() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let una = Unico()
            oyente.stateUpdateHandler = { estado in
                switch estado {
                case .ready: if una.primero() { c.resume() }
                case .failed(let e): if una.primero() { c.resume(throwing: e) }
                default: break
                }
            }
            oyente.start(queue: cola)
        }
        return oyente.port!.rawValue
    }

    func apagar() {
        oyente.cancel()
        candado.withLock { clientes.forEach { $0.cancel() }; clientes.removeAll() }
    }

    /// Cierra las conexiones abiertas pero sigue escuchando, como cuando el
    /// receptor se reinicia o el router cambia de canal.
    func cortarConexiones() {
        candado.withLock { clientes.forEach { $0.cancel() }; clientes.removeAll() }
    }

    func valor(_ codigo: String) -> String? { candado.withLock { estado[codigo] } }

    /// Lo que pasa cuando alguien usa el control de fábrica: el receptor
    /// avisa a todos los conectados sin que nadie le pregunte.
    func cambiarDesdeElControl(_ codigo: String, _ valor: String) {
        candado.withLock { estado[codigo] = valor }
        avisarATodos("\(codigo)\(valor)")
    }

    private func atender(_ conexion: NWConnection) {
        candado.withLock { clientes.append(conexion) }
        conexion.start(queue: cola)
        leer(conexion, bufer: Data())
    }

    private func leer(_ conexion: NWConnection, bufer: Data) {
        conexion.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] datos, _, completo, error in
            guard let self, error == nil else { return }
            var bufer = bufer
            if let datos { bufer.append(datos) }
            for comando in EISCP.extraer(de: &bufer) { self.procesar(comando) }
            if !completo { self.leer(conexion, bufer: bufer) }
        }
    }

    private func procesar(_ comando: String) {
        let codigo = String(comando.prefix(3))
        let valor = String(comando.dropFirst(3))
        let respuesta: String? = candado.withLock {
            recibidos.append(comando)
            guard estado[codigo] != nil else { return nil }
            switch valor {
            case "QSTN": break
            case "UP", "DOWN":
                let actual = Int(estado[codigo]!, radix: 16)!
                let nuevo = min(max(actual + (valor == "UP" ? 1 : -1), 0), 80)
                estado[codigo] = String(format: "%02X", nuevo)
            default:
                estado[codigo] = valor
            }
            return "\(codigo)\(estado[codigo]!)"
        }
        if let respuesta { avisarATodos(respuesta) }
    }

    private func avisarATodos(_ mensaje: String) {
        let paquete = EISCP.paquete(mensaje)
        let conectados = candado.withLock { clientes }
        for c in conectados {
            if partirRespuestas {
                c.send(content: paquete.prefix(10), completion: .idempotent)
                c.send(content: paquete.dropFirst(10), completion: .idempotent)
            } else {
                c.send(content: paquete, completion: .idempotent)
            }
        }
    }
}
