import Foundation
import Network

/// Encuentra servicios anunciados por Bonjour y regresa su dirección. Google
/// TV y Apple TV se anuncian solos; no hace falta barrer la red como con el
/// Onkyo.
nonisolated enum BuscadorBonjour {
    typealias Hallazgo = (nombre: String, host: String, puerto: UInt16)

    /// La dirección y el puerto del primero que conteste y pase el filtro.
    /// Companion cambia de puerto según el aparato, así que el puerto también
    /// se lee del anuncio.
    ///
    /// `acepta` revisa el registro TXT del anuncio: en una casa con Macs y
    /// iPads, todos anuncian Companion, y el primero en contestar casi nunca
    /// es la tele.
    static func primero(
        _ tipo: String,
        limite: Duration,
        acepta: @escaping @Sendable ([String: String]) -> Bool = { _ in true }
    ) async -> (host: String, puerto: UInt16)? {
        guard let servicio = await anuncios(tipo, limite: limite, acepta: acepta, basta: 1).first,
              let d = await resolver(servicio.endpoint) else { return nil }
        return (d.host, d.puerto)
    }

    /// Todos los que contesten en `limite`, para la pantalla de agregar.
    static func todos(
        _ tipo: String,
        limite: Duration,
        acepta: @escaping @Sendable ([String: String]) -> Bool = { _ in true }
    ) async -> [Hallazgo] {
        let servicios = await anuncios(tipo, limite: limite, acepta: acepta, basta: nil)
        return await withTaskGroup(of: Hallazgo?.self) { grupo in
            for s in servicios {
                grupo.addTask {
                    guard let d = await resolver(s.endpoint) else { return nil }
                    return (s.nombre, d.host, d.puerto)
                }
            }
            var lista: [Hallazgo] = []
            for await h in grupo { if let h { lista.append(h) } }
            return lista
        }
    }

    // MARK: - Privado

    private struct Anuncio: @unchecked Sendable {
        let nombre: String
        let endpoint: NWEndpoint
    }

    /// Escucha anuncios durante `limite`, o hasta juntar `basta`.
    private static func anuncios(
        _ tipo: String,
        limite: Duration,
        acepta: @escaping @Sendable ([String: String]) -> Bool,
        basta: Int?
    ) async -> [Anuncio] {
        let navegador = NWBrowser(for: .bonjourWithTXTRecord(type: tipo, domain: nil), using: .tcp)
        let cola = DispatchQueue(label: "mx.alfonsoleal.mando.bonjour")
        let vistos = Caja<[Anuncio]>()
        vistos.valor = []
        let resultado: [Anuncio] = await withCheckedContinuation { c in
            let una = Unico()
            navegador.browseResultsChangedHandler = { resultados, _ in
                let elegidos = resultados.compactMap { r -> Anuncio? in
                    let txt: [String: String]
                    if case .bonjour(let registro) = r.metadata { txt = registro.dictionary } else { txt = [:] }
                    guard acepta(txt) else { return nil }
                    var nombre = ""
                    if case .service(let n, _, _, _) = r.endpoint { nombre = n }
                    return Anuncio(nombre: nombre, endpoint: r.endpoint)
                }
                vistos.valor = elegidos
                if let basta, elegidos.count >= basta, una.primero() { c.resume(returning: elegidos) }
            }
            navegador.start(queue: cola)
            let milisegundos = Int(limite.components.seconds * 1000 + limite.components.attoseconds / 1_000_000_000_000_000)
            cola.asyncAfter(deadline: .now() + .milliseconds(milisegundos)) {
                if una.primero() { c.resume(returning: vistos.valor ?? []) }
            }
        }
        navegador.cancel()
        return resultado
    }

    /// Para tener la IP hay que conectar una vez al servicio y leer a dónde
    /// llegó la conexión.
    /// Primero IPv4, que se lee y se puede escribir a mano. Algunos aparatos
    /// (el Google TV con que se probó) sólo anuncian IPv6: entonces se usa ésa,
    /// completa con su interfaz («fe80::…%en0»), que sin ella no sirve.
    private static func resolver(_ servicio: NWEndpoint) async -> (host: String, puerto: UInt16)? {
        if let v4 = await resolver(servicio, version: .v4) { return v4 }
        return await resolver(servicio, version: .any)
    }

    private static func resolver(_ servicio: NWEndpoint, version: NWProtocolIP.Options.Version) async -> (host: String, puerto: UInt16)? {
        let cola = DispatchQueue(label: "mx.alfonsoleal.mando.bonjour.resolver")
        let parametros = NWParameters.tcp
        (parametros.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = version
        let c = NWConnection(to: servicio, using: parametros)
        let encontrado: (host: String, puerto: UInt16)? = await withCheckedContinuation { cont in
            let una = Unico()
            c.stateUpdateHandler = { estado in
                switch estado {
                case .ready:
                    var texto: String?
                    var puerto: UInt16 = 0
                    if case .hostPort(let h, let p) = c.currentPath?.remoteEndpoint {
                        puerto = p.rawValue
                        switch h {
                        case .ipv4(let ip): texto = "\(ip)".components(separatedBy: "%").first
                        case .ipv6(let ip): texto = "\(ip)"
                        case .name(let n, _): texto = n
                        @unknown default: texto = nil
                        }
                    }
                    if una.primero() { cont.resume(returning: texto.map { ($0, puerto) }) }
                case .failed, .cancelled:
                    if una.primero() { cont.resume(returning: nil) }
                default: break
                }
            }
            c.start(queue: cola)
            cola.asyncAfter(deadline: .now() + 3) { if una.primero() { cont.resume(returning: nil) } }
        }
        c.cancel()
        return encontrado
    }
}
