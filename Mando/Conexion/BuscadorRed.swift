import Foundation
import Network

/// Busca un aparato en la subred probando sus puertos en cada dirección. El
/// descubrimiento oficial del Onkyo y de las LG es por broadcast UDP, pero en
/// iOS eso pide un permiso de multicast que Apple aprueba a mano; una conexión
/// TCP sólo pide el permiso de red local.
nonisolated enum BuscadorRed {
    /// La primera dirección con todos `puertos` abiertos. Pedir más de uno
    /// evita confundir la tele con una Mac que tenga un servidor de
    /// desarrollo en el 3000.
    static func buscar(puertos: [UInt16]) async -> String? {
        guard let candidatos = direccionesVecinas() else { return nil }
        return await withTaskGroup(of: String?.self) { grupo in
            var pendientes = candidatos.makeIterator()
            // De 64 en 64: más abre demasiados sockets a la vez en el iPhone.
            for _ in 0..<64 {
                guard let ip = pendientes.next() else { break }
                grupo.addTask { await responde(ip, puertos) ? ip : nil }
            }
            for await resultado in grupo {
                if let ip = resultado {
                    grupo.cancelAll()
                    return ip
                }
                if let ip = pendientes.next() {
                    grupo.addTask { await responde(ip, puertos) ? ip : nil }
                }
            }
            return nil
        }
    }

    /// Recorre todas las direcciones vecinas, de 64 en 64, y llama a
    /// `cadaIP` con cada una. Para la pantalla de agregar, que quiere todo lo
    /// que haya y no sólo el primero.
    static func barrer(_ cadaIP: @escaping @Sendable (String) async -> Void) async {
        guard let candidatos = direccionesVecinas() else { return }
        await withTaskGroup { grupo in
            var pendientes = candidatos.makeIterator()
            for _ in 0..<64 {
                guard let ip = pendientes.next() else { break }
                grupo.addTask { await cadaIP(ip) }
            }
            for await _ in grupo {
                if Task.isCancelled { grupo.cancelAll(); return }
                if let ip = pendientes.next() { grupo.addTask { await cadaIP(ip) } }
            }
        }
    }

    static func contesta(_ ip: String, _ puerto: UInt16) async -> Bool {
        guard let c = try? await TCP.conectar(a: ip, puerto: puerto, limite: .milliseconds(600)) else { return false }
        c.cancel()
        return true
    }

    private static func responde(_ ip: String, _ puertos: [UInt16]) async -> Bool {
        for puerto in puertos {
            guard let c = try? await TCP.conectar(a: ip, puerto: puerto, limite: .milliseconds(600)) else {
                return false
            }
            c.cancel()
        }
        return true
    }

    /// Las direcciones de la red Wi-Fi o Ethernet del aparato. Si la red es
    /// más grande que /22 sólo se recorre el bloque de 1024 donde está el
    /// propio aparato, para que la búsqueda no dure minutos.
    static func direccionesVecinas() -> [String]? {
        var lista: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&lista) == 0, let primera = lista else { return nil }
        defer { freeifaddrs(lista) }
        for ptr in sequence(first: primera, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            let nombre = String(cString: i.ifa_name)
            guard nombre.hasPrefix("en"),
                  let dir = i.ifa_addr, dir.pointee.sa_family == UInt8(AF_INET),
                  let mascara = i.ifa_netmask else { continue }
            let propia = dir.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var red = mascara.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            red = max(red, 0xFFFF_FC00)
            let base = propia & red
            let total = ~red
            guard total > 1 else { continue }
            return (1..<total).map { n in
                let ip = base | n
                return "\(ip >> 24).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
            }.filter { $0 != texto(propia) }
        }
        return nil
    }

    private static func texto(_ ip: UInt32) -> String {
        "\(ip >> 24).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }
}
