import Foundation
import Network

/// Busca en la red todos los aparatos que la app sabe controlar y los va
/// entregando conforme aparecen: los que se anuncian por Bonjour (Apple TV y
/// Google TV) en un par de segundos, los que hay que barrer (Onkyo y LG) en
/// lo que tarda recorrer la subred.
nonisolated enum Descubridor {
    struct Encontrado: Identifiable, Equatable, Sendable {
        var id: String { "\(tipo.rawValue)-\(host)" }
        let tipo: TipoAparato
        let nombre: String
        let host: String
        let puerto: UInt16?
    }

    static func buscar() -> AsyncStream<Encontrado> {
        AsyncStream { salida in
            let tarea = Task {
                await withTaskGroup { grupo in
                    grupo.addTask {
                        for e in await BuscadorBonjour.todos(ControladorAppleTV.servicioBonjour, limite: .seconds(4), acepta: ControladorAppleTV.esAppleTV) {
                            salida.yield(Encontrado(tipo: .appleTV, nombre: e.nombre, host: e.host, puerto: e.puerto))
                        }
                    }
                    grupo.addTask {
                        for e in await BuscadorBonjour.todos(AndroidTV.servicioBonjour, limite: .seconds(4)) {
                            salida.yield(Encontrado(tipo: .googleTV, nombre: e.nombre, host: e.host, puerto: nil))
                        }
                    }
                    grupo.addTask {
                        // Un solo barrido para los dos: cada dirección se prueba
                        // una vez por puerto, no una vez por tipo de aparato.
                        await BuscadorRed.barrer { ip in
                            if await BuscadorRed.contesta(ip, EISCP.puerto) {
                                salida.yield(Encontrado(tipo: .onkyo, nombre: "Onkyo", host: ip, puerto: nil))
                            }
                            if await BuscadorRed.contesta(ip, 3001), await BuscadorRed.contesta(ip, 3000) {
                                salida.yield(Encontrado(tipo: .lg, nombre: "Tele LG", host: ip, puerto: nil))
                            }
                        }
                    }
                }
                salida.finish()
            }
            salida.onTermination = { _ in tarea.cancel() }
        }
    }
}
