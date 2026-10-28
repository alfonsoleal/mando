import Foundation
import Network

/// Una conexión TCP que habla HTTP o RTSP y que, después de verificar, cifra
/// todo lo que pasa por ella con los bloques de HomeKit. AirPlay usa tres así:
/// la de control, la de avisos y la de datos.
actor Tubo {
    let conexion: NWConnection
    private var canal: CanalHAP?
    /// Lo que llegó cifrado y todavía no completa un bloque.
    private var cifrado = Data()
    /// Lo que ya se descifró y nadie ha leído.
    private var claro = Data()

    init(_ conexion: NWConnection) {
        self.conexion = conexion
    }

    /// A partir de aquí, todo va cifrado en los dos sentidos.
    func cifrar(con canal: CanalHAP) {
        self.canal = canal
    }

    func enviar(_ datos: Data) async throws {
        var salida = datos
        if var c = canal {
            salida = try c.cifrar(datos)
            canal = c
        }
        try await TCP.mandar(salida, por: conexion)
    }

    /// Trae más bytes de la red (descifrados si toca). Falla si la conexión
    /// se cerró o no llegó nada a tiempo.
    func leerMas(limite: Duration) async throws {
        guard let datos = try await TCP.recibir(de: conexion, limite: limite) else { throw TCP.SinRespuesta() }
        if var c = canal {
            cifrado.append(datos)
            claro.append(try c.descifrar(&cifrado))
            canal = c
        } else {
            claro.append(datos)
        }
    }

    /// Saca `n` bytes de lo leído, esperando a que lleguen.
    func tomar(_ n: Int, limite: Duration = .seconds(5)) async throws -> Data {
        while claro.count < n { try await leerMas(limite: limite) }
        let d = claro.prefix(n)
        claro.removeFirst(n)
        return Data(d)
    }

    /// El siguiente mensaje HTTP o RTSP completo: encabezados y cuerpo según
    /// Content-Length.
    func mensaje(limite: Duration = .seconds(5)) async throws -> MensajeHTTP {
        let fin = Data("\r\n\r\n".utf8)
        while claro.range(of: fin) == nil { try await leerMas(limite: limite) }
        let corte = claro.range(of: fin)!
        let cabeza = String(decoding: claro[claro.startIndex..<corte.lowerBound], as: UTF8.self)
        claro.removeSubrange(claro.startIndex..<corte.upperBound)
        var lineas = cabeza.components(separatedBy: "\r\n")
        let primera = lineas.removeFirst()
        var encabezados: [String: String] = [:]
        for l in lineas {
            guard let dos = l.firstIndex(of: ":") else { continue }
            encabezados[l[..<dos].lowercased()] = l[l.index(after: dos)...].trimmingCharacters(in: .whitespaces)
        }
        let largo = Int(encabezados["content-length"] ?? "0") ?? 0
        let cuerpo = try await tomar(largo, limite: limite)
        return MensajeHTTP(primeraLinea: primera, encabezados: encabezados, cuerpo: cuerpo)
    }

    func cerrar() {
        conexion.cancel()
    }
}

nonisolated struct MensajeHTTP: Sendable {
    let primeraLinea: String
    let encabezados: [String: String]
    let cuerpo: Data

    /// El código de una respuesta («RTSP/1.0 200 OK» → 200).
    var codigo: Int? {
        let partes = primeraLinea.split(separator: " ")
        return partes.count > 1 ? Int(partes[1]) : nil
    }

    var plist: [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: cuerpo, format: nil)) as? [String: Any]
    }

    static func peticion(_ linea: String, encabezados: [(String, String)], cuerpo: Data = Data()) -> Data {
        var texto = linea + "\r\n"
        for (k, v) in encabezados { texto += "\(k): \(v)\r\n" }
        if !cuerpo.isEmpty { texto += "Content-Length: \(cuerpo.count)\r\n" }
        texto += "\r\n"
        return Data(texto.utf8) + cuerpo
    }
}
