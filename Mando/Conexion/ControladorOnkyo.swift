import Foundation
import Network

/// Habla con un receptor Onkyo por eISCP (TCP 60128). Si no se le da una
/// dirección, lo busca en la red de la casa la primera vez que conecta.
actor ControladorOnkyo: Controlador {
    nonisolated let reportes: AsyncStream<Reporte>
    private nonisolated let avisar: AsyncStream<Reporte>.Continuation

    private var host: String?
    private let puerto: UInt16
    private let buscarSiFalla: Bool
    private var conexion: NWConnection?
    private var lectura: Task<Void, Never>?
    private var enCurso: Task<Void, Error>?

    /// `buscarSiFalla`: si la dirección guardada ya no contesta (el router le
    /// dio otra IP), se barre la red otra vez.
    init(host: String? = nil, puerto: UInt16 = EISCP.puerto, buscarSiFalla: Bool = true) {
        self.host = host
        self.puerto = puerto
        self.buscarSiFalla = buscarSiFalla
        (reportes, avisar) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    func conectar() async throws {
        if let conexion, conexion.state == .ready { return }
        // Dos conexiones a la vez (volver a la app mientras se aprieta una
        // tecla) dejarían una colgada: la segunda espera a la primera.
        if let enCurso { return try await enCurso.value }
        let t = Task { try await abrir() }
        enCurso = t
        defer { enCurso = nil }
        try await t.value
    }

    private func abrir() async throws {
        soltar()
        let guardado = host
        if host == nil { host = await BuscadorRed.buscar(puertos: [EISCP.puerto]) }
        guard let host else { throw ErrorControl.onkyoNoEncontrado }
        do {
            let nueva: NWConnection
            do {
                nueva = try await TCP.conectar(a: host, puerto: puerto, limite: .seconds(3))
            } catch where guardado != nil && buscarSiFalla {
                self.host = nil
                return try await abrir()
            }
            avisar.yield(.direccion(host: host, puerto: puerto))
            conexion = nueva
            leer(nueva)
            for pregunta in EISCP.preguntas {
                try await TCP.mandar(EISCP.paquete(pregunta), por: nueva)
            }
        } catch let error as ErrorControl {
            soltar()
            throw error
        } catch {
            soltar()
            throw ErrorControl.sinRespuesta("El Onkyo")
        }
    }

    func mandar(_ orden: Orden) async throws {
        let comandos = EISCP.comandos(para: orden)
        guard !comandos.isEmpty else { throw ErrorControl.noSoportada(orden, .onkyo) }
        // Si la conexión se cayó (el receptor se reinició, cambió la Wi-Fi),
        // se vuelve a abrir aquí en vez de pedirle al usuario que reintente.
        try await conectar()
        guard let conexion else { throw ErrorControl.sinRespuesta("El Onkyo") }
        do {
            for comando in comandos {
                try await TCP.mandar(EISCP.paquete(comando), por: conexion)
            }
        } catch {
            soltar()
            throw ErrorControl.sinRespuesta("El Onkyo")
        }
    }

    private func leer(_ conexion: NWConnection) {
        lectura = Task {
            var bufer = Data()
            while !Task.isCancelled {
                guard let datos = try? await TCP.recibir(de: conexion) else {
                    soltar()
                    return
                }
                bufer.append(datos)
                for mensaje in EISCP.extraer(de: &bufer) {
                    if let reporte = EISCP.reporte(de: mensaje) { avisar.yield(reporte) }
                }
            }
        }
    }

    private func soltar() {
        lectura?.cancel()
        lectura = nil
        conexion?.cancel()
        conexion = nil
    }
}
