import Foundation
import Network

/// Lo mínimo de TCP que necesitan los controladores, con async/await encima de
/// Network.framework y un tiempo límite: un aparato apagado no rechaza la
/// conexión, simplemente nunca contesta.
nonisolated enum TCP {
    struct SinRespuesta: Error {}

    static func conectar(
        a host: String,
        puerto: UInt16,
        limite: Duration,
        parametros: NWParameters = .tcp
    ) async throws -> NWConnection {
        try await conectar(
            a: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: puerto)!),
            limite: limite,
            parametros: parametros
        )
    }

    static func conectar(a destino: NWEndpoint, limite: Duration, parametros: NWParameters) async throws -> NWConnection {
        let conexion = NWConnection(to: destino, using: parametros)
        let cola = DispatchQueue(label: "mx.alfonsoleal.mando.tcp")
        let listo = Unico()
        // El límite vive en la misma cola que los estados, no en una tarea
        // aparte: cancelar una tarea no resuelve una continuación pendiente, y
        // la búsqueda se quedaba esperando para siempre a una IP sin nadie.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conexion.stateUpdateHandler = { estado in
                switch estado {
                case .ready: if listo.primero() { c.resume() }
                // «waiting» es que no hay ruta o nadie escucha: para un control
                // remoto es lo mismo que un error.
                case .failed, .waiting:
                    if listo.primero() { conexion.cancel(); c.resume(throwing: SinRespuesta()) }
                case .cancelled: if listo.primero() { c.resume(throwing: CancellationError()) }
                default: break
                }
            }
            conexion.start(queue: cola)
            let nanos = limite.components.seconds * 1_000_000_000 + limite.components.attoseconds / 1_000_000_000
            cola.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                if listo.primero() { conexion.cancel(); c.resume(throwing: SinRespuesta()) }
            }
        }
        return conexion
    }

    static func mandar(_ datos: Data, por conexion: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conexion.send(content: datos, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    /// Como `recibir`, pero si no llega nada a tiempo corta la conexión: así
    /// la lectura pendiente termina en vez de quedarse esperando.
    static func recibir(de conexion: NWConnection, limite: Duration) async throws -> Data? {
        let vigente = Unico()
        let nanos = limite.components.seconds * 1_000_000_000 + limite.components.attoseconds / 1_000_000_000
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(max(nanos, 0)))) {
            if vigente.primero() { conexion.cancel() }
        }
        defer { _ = vigente.primero() }
        return try await recibir(de: conexion)
    }

    /// Lee lo que llegue. Regresa nil cuando el otro lado cerró.
    static func recibir(de conexion: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            conexion.receive(minimumIncompleteLength: 1, maximumLength: 8192) { datos, _, completo, error in
                if let error { c.resume(throwing: error); return }
                if let datos, !datos.isEmpty { c.resume(returning: datos); return }
                c.resume(returning: completo ? nil : Data())
            }
        }
    }
}

nonisolated enum TLS {
    /// Parámetros de TLS que presentan nuestro certificado y aceptan el de la
    /// tele aunque sea autofirmado (todas las teles lo son), guardando su llave
    /// pública: el código de emparejamiento se calcula con ella.
    static func parametros(identidad: SecIdentity?, llaveDelOtro: Caja<SecKey> = Caja()) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let opciones = tls.securityProtocolOptions
        if let identidad {
            sec_protocol_options_set_local_identity(opciones, sec_identity_create(identidad)!)
        }
        sec_protocol_options_set_min_tls_protocol_version(opciones, .TLSv12)
        sec_protocol_options_set_verify_block(opciones, { _, confianza, listo in
            let trust = sec_trust_copy_ref(confianza).takeRetainedValue()
            if let cadena = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let primero = cadena.first {
                llaveDelOtro.valor = SecCertificateCopyKey(primero)
            }
            listo(true)
        }, DispatchQueue(label: "mx.alfonsoleal.mando.tls"))
        return NWParameters(tls: tls)
    }
}

/// Un valor que se llena desde otra cola (el bloque de verificación de TLS).
nonisolated final class Caja<T>: @unchecked Sendable {
    private let candado = NSLock()
    private var _valor: T?
    var valor: T? {
        get { candado.withLock { _valor } }
        set { candado.withLock { _valor = newValue } }
    }
    init() {}
}

/// Para que la continuación se resuelva una sola vez aunque Network avise
/// varios estados seguidos.
nonisolated final class Unico: @unchecked Sendable {
    private let candado = NSLock()
    private var usado = false

    func primero() -> Bool {
        candado.withLock {
            defer { usado = true }
            return !usado
        }
    }
}
